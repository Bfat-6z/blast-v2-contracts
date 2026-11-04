// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Aftermath sale-token preparation, permissionless migration into `blast_vault` custody, and
/// LP-fee collection for presales.
///
/// A funded sale migrates into a fresh 50/50 Aftermath weighted pool wrapped in Aftermath's
/// DAO-fee pool. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as separate
/// coins sent straight to the fee recipient address, so `migrate` builds the sale's vault first and
/// names its address as that recipient: the fee coins land owned by the vault object, and anyone
/// may then receive them into the vault, where they are split like any collection. The LP coin,
/// the whole pool liquidity, is sent to `0x0`, so the pool's liquidity is locked for good; the
/// vault's position is the DAO-fee pool's `OwnerCap`, which could otherwise change the fee or
/// redirect it, under the venue's sealed position key with no removal path.
///
/// Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly published LP coin,
/// so the creator publishes one per sale and hands its capability to `prepare`, which keeps it
/// under the sale token's and the LP coin's types; only that sale's migration, naming the same LP
/// coin, consumes it (ADR 0137 supersedes ADR 0116's `FinalizeTicket`).
///
/// Aftermath's registry rejects a second pool with the same coins, weights, flatness, and fees,
/// but no sale token circulates before migration, so nobody can create the sale's pool first and
/// the migration creates it with the module's fixed terms.
module blast_presale::aftermath;

// === Public Types ===

/// The Aftermath venue's sealed witness: it issues tickets, redeems migrations, and keys the
/// DAO-fee pool owner cap in the vault, so the creation policy and the vault registry admit this
/// one type.
public struct Venue() has drop;

/// Key for a sale token's reserved Aftermath pool-creation capability, minted by the LP coin `Lp`.
public struct CreatePoolCapKey<phantom Lp, phantom Meme>() has copy, drop, store;

// === Public Functions ===

/// Prepares `Meme` for a presale in `Quote` that migrates to an Aftermath pool charging
/// `dao_fee_bps` of every swap, deposit, and withdrawal to the sale's vault, and returns the
/// ticket `blast_presale::new` redeems. It keeps `create_pool_cap`, which the fresh LP coin `Lp`
/// minted, for the sale's migration. The fee is the sale's pool tier, recorded under its token's
/// type with no tick spacing; the pool's weights and base fee are this module's constants. The
/// treasury capability proves the caller controls the token, so no one else can reserve it first.
public fun prepare<Lp, Meme, Quote>(
    package_version: &PackageVersion,
    venue_config: &mut VenueConfig,
    _: &TreasuryCap<Meme>,
    create_pool_cap: CreatePoolCapV2,
    dao_fee_bps: u16,
): VenueTicket<Meme, Quote> {
    package_version.assert_current();

    assert!(
        dao_fee_bps > 0 && dao_fee_bps <= constants::aftermath_max_dao_fee_bps!(),
        blast_presale::errors::invalid_dao_fee!(),
    );

    let create_pool_cap_id = object::id(&create_pool_cap);
    venue_config.add_object(CreatePoolCapKey<Lp, Meme>(), create_pool_cap);
    venue_config.add_pool_tier<Meme, Quote, _>(&Venue(), 0, dao_fee_bps as u64);

    event::emit(PoolCreationReserved<Lp, Meme, Quote> { create_pool_cap_id });

    migration::issue_ticket(Venue())
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded presale into its reserved Aftermath pool, consuming the capability
/// `prepare` kept for the LP coin `Lp`: it seeds a 50/50 pool with all of the sale's LP tokens and
/// Quote, builds the sale's vault, wraps the pool in a DAO-fee pool paying the vault at the fee
/// `prepare` recorded, shares that pool, locks the pool's owner cap in the vault as its position,
/// shares the vault, and sends the LP coin to `0x0`.
#[allow(lint(share_owned))]
public fun migrate<Lp, Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    venue_config: &mut VenueConfig,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    registry: &VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let create_pool_cap = venue_config.remove_object(CreatePoolCapKey<Lp, Meme>());
    let (_, pool_fee_rate) = venue_config.pool_tier<Meme>();
    let dao_fee_bps = pool_fee_rate as u16;
    let (meme, quote, terms) = sale
        .migrate(package_version, fee_policy, clock, ctx)
        .redeem(Venue());
    let (meme_amount, quote_amount) = (meme.value(), quote.value());

    let (pool, lp) = create_pool<Lp, _, _>(
        create_pool_cap,
        pool_registry,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        ctx,
    );
    assert_pool_balances!(
        pool.balance_of<Lp, Meme>(),
        meme_amount,
        pool.balance_of<Lp, Quote>(),
        quote_amount,
    );

    let pool_id = object::id(&pool);
    let vault = vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id, ctx);
    let vault_address = object::id(&vault).to_address();
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        dao_fee_bps,
        vault_address,
        ctx,
    );
    assert_dao_fee_terms!(
        dao_fee_pool.fee_bps(),
        dao_fee_bps,
        dao_fee_pool.fee_recipient(),
        vault_address,
    );

    event::emit(DaoFeePoolCreated<Lp, Meme, Quote> {
        vault_id: object::id(&vault),
        pool_id,
        dao_fee_pool_id: object::id(&dao_fee_pool),
        owner_cap_id: object::id(&owner_cap),
        lp_coin_id: object::id(&lp),
    });

    vault.share_with_position(
        &Venue(),
        treasury,
        owner_cap,
        lp.value() as u128,
        balance::zero(),
        balance::zero(),
        ctx,
    );
    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(lp, @0x0);
}

/// Anyone may receive the DAO fees Aftermath sent to an Aftermath vault's address, one
/// `Receiving` per fee coin, and split them through the vault. An empty collection is valid.
/// Another venue's vault aborts in the vault: its fees settle only through its own venue.
public fun collect_fees<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let meme = vault.receive_fees(vault_version, meme_fees);
    let quote = vault.receive_fees(vault_version, quote_fees);

    vault.split_fees(&Venue(), vault_version, treasury, currency, meme, quote, ctx);
}

/// Anyone may activate an Aftermath vault's ready split. Aftermath pays fees as separate coins:
/// unreceived coins follow the applied split when they are later collected.
public fun apply_fee_split<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current();
    vault.assert_fee_split_ready(clock);

    vault.apply_fee_split(&Venue(), vault_version, clock);
}

// === Private Functions ===

// Lazy arguments preserve short-circuit order for the external reads.
macro fun assert_pool_balances(
    $actual_meme: u64,
    $expected_meme: u64,
    $actual_quote: u64,
    $expected_quote: u64
) {
    assert_pool_balance($actual_meme, $expected_meme);
    assert_pool_balance($actual_quote, $expected_quote);
}

macro fun assert_dao_fee_terms(
    $actual_bps: u16,
    $expected_bps: u16,
    $actual_recipient: address,
    $expected_recipient: address
) {
    assert_dao_fee_term($actual_bps, $expected_bps);
    assert_dao_fee_term($actual_recipient, $expected_recipient);
}

fun assert_pool_balance(actual: u64, expected: u64) {
    assert!(actual == expected, blast_presale::errors::pool_mismatch!());
}

fun assert_dao_fee_term<T: drop>(actual: T, expected: T) {
    assert!(actual == expected, blast_presale::errors::dao_fee_pool_mismatch!());
}

/// Creates the 50/50 pool from the sale's tokens and Quote, in Aftermath's coin order.
fun create_pool<Lp, Meme, Quote>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    if (sorts_before<Meme, Quote>()) {
        create_pool_2_coins(create_pool_cap, pool_registry, meme, quote, ctx)
    } else {
        create_pool_2_coins(create_pool_cap, pool_registry, quote, meme, ctx)
    }
}

/// Creates the pool from both coins, which must be in Aftermath's coin order.
fun create_pool_2_coins<Lp, Coin1, Coin2>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    coin_1: Coin<Coin1>,
    coin_2: Coin<Coin2>,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    pool_factory::create_pool_2_coins_v2(
        create_pool_cap,
        pool_registry,
        constants::aftermath_pool_name!(),
        vector[constants::aftermath_half_weight!(), constants::aftermath_half_weight!()],
        constants::aftermath_flatness!(),
        vector[constants::aftermath_base_swap_fee!(), constants::aftermath_base_swap_fee!()],
        vector[0, 0],
        vector[0, 0],
        vector[0, 0],
        coin_1,
        coin_2,
        option::none(),
        false,
        ctx,
    )
}

/// Whether `A` comes before `B` in Aftermath's coin order: the byte order of their defining-ID type
/// names, which its pool registry requires.
fun sorts_before<A, B>(): bool {
    let a_name = type_name::with_defining_ids<A>().into_string().into_bytes();
    let b_name = type_name::with_defining_ids<B>().into_string().into_bytes();
    let prefix_length = a_name.length().min(b_name.length());
    let mut i = 0;
    while (i < prefix_length && a_name[i] == b_name[i]) i = i + 1;

    // The first differing byte decides; otherwise the shorter name is a prefix and comes first.
    if (i < prefix_length) return a_name[i] < b_name[i];

    a_name.length() < b_name.length()
}

/// Receives every listed fee coin into the vault and joins them into one balance.
fun receive_fees<Meme, Quote, Asset>(
    vault: &mut Vault<Meme, Quote>,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    fees: vector<Receiving<Coin<Asset>>>,
): Balance<Asset> {
    let mut received = balance::zero<Asset>();
    fees.do!(|fee| {
        received.join(vault.receive_coin(&Venue(), vault_version, fee));
    });

    received
}

// === Test-Only Functions ===

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
/// Runs `migrate`'s redemption and vault creation, unshared first as `migrate` builds it, with
/// `position` in place of the DAO-fee pool's owner cap, keeping the whole hand-off as the owner's
/// residuals: the Aftermath link stubs cannot create a pool in unit tests. Returns the vault's ID.
public fun migrate_for_testing<Meme, Quote, Position: key + store>(
    sale: &mut Presale<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    registry: &VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    position: Position,
    pool_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let (meme, quote, terms) = sale
        .migrate(package_version, fee_policy, clock, ctx)
        .redeem(Venue());
    let vault = vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id, ctx);
    let vault_id = object::id(&vault);

    vault.share_with_position(&Venue(), treasury, position, 1, meme, quote, ctx);

    vault_id
}

#[test_only]
public fun pool_creation_reserved_fields<Lp, Meme, Quote>(
    event: &PoolCreationReserved<Lp, Meme, Quote>,
): ID {
    event.create_pool_cap_id
}

#[test_only]
public fun dao_fee_pool_created_fields<Lp, Meme, Quote>(
    event: &DaoFeePoolCreated<Lp, Meme, Quote>,
): (ID, ID, ID, ID, ID) {
    (event.vault_id, event.pool_id, event.dao_fee_pool_id, event.owner_cap_id, event.lp_coin_id)
}

#[test_only]
public fun assert_pool_balances_for_testing(
    actual_meme: u64,
    expected_meme: u64,
    actual_quote: u64,
    expected_quote: u64
) {
    assert_pool_balances!(actual_meme, expected_meme, actual_quote, expected_quote);
}

#[test_only]
public fun assert_dao_fee_terms_for_testing(
    actual_bps: u16,
    expected_bps: u16,
    actual_recipient: address,
    expected_recipient: address
) {
    assert_dao_fee_terms!(actual_bps, expected_bps, actual_recipient, expected_recipient);
}

#[test_only]
public fun assert_pool_short_circuit_for_testing() {
    assert_pool_balances!(99, 100, abort, 200);
}

#[test_only]
public fun assert_dao_fee_short_circuit_for_testing() {
    assert_dao_fee_terms!(199, 200, abort, @0xA);
}

// === Events ===

/// `prepare` reserved the `Meme` sale's Aftermath pool creation for the LP coin `Lp` with the
/// capability `create_pool_cap_id`, which the sale's migration consumes.
public struct PoolCreationReserved<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    create_pool_cap_id: ID,
}

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id` paying its fees to the vault `vault_id`. The vault holds that
/// pool's owner cap `owner_cap_id` as its position, and the LP coin `lp_coin_id`, the whole pool
/// liquidity, is owned by `0x0`.
public struct DaoFeePoolCreated<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
    lp_coin_id: ID,
}

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_admin::package_version::PackageVersion as VaultVersion;

use blast_core::{blast_treasury::Treasury, migration::{Self, VenueTicket}};

use blast_presale::{
    blast_presale::Presale,
    blast_presale_package::PackageVersion,
    constants,
    fee_policy::FeePolicy,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    event,
    transfer::Receiving
};

use fun receive_fees as Vault.receive_fees;
