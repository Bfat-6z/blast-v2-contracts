// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A one-off presale venue built for a partner, over `blast_core` alone. The `AdminCap` prepares
/// each sale token with the Aftermath pool-creation capability of its LP coin and receives the
/// `VenueTicket` that `blast_presale::new` redeems, so the sale can migrate only here. Anyone may
/// then migrate the funded sale: the PTB passes the `Migration` the presale's own `migrate`
/// returned, and this module seeds a 50/50 Aftermath weighted pool wrapped in Aftermath's DAO-fee
/// pool, which pays a 2% fee on every swap, deposit, and withdrawal straight to the partner
/// treasury. The treasury also receives each DAO-fee pool's owner cap, with which it may change
/// that pool's fee or recipient; the sale's LP is locked forever.
///
/// The package never imports a product, so a presale upgrade never strands it.
module blast_aftermath_dao_presale::blast_aftermath_dao_presale;

// === Public Types ===

/// The package's sealed venue witness: it issues the ticket a sale redeems at creation and
/// redeems that sale's migration hand-off. Only this module constructs it, so only `migrate` can
/// release the sale's liquidity.
public struct Venue() has drop;

/// The package's only administrator, sent to the publisher at publication. Its one power is
/// preparing sale tokens through `prepare`.
public struct AdminCap has key, store {
    id: UID,
}

/// Shared reservation of one sale token's Aftermath pool creation: the `CreatePoolCapV2` of the
/// fresh LP coin `Lp`, which only the migration of a `SaleToken` sale whose terms `issuer` sealed
/// can consume.
public struct PoolCreation<phantom Lp, phantom SaleToken> has key {
    id: UID,
    /// The original type of the product witness the `AdminCap` holder named at `prepare`; a
    /// `Migration` whose terms another package sealed cannot consume this reservation.
    issuer: TypeName,
    create_pool_cap: CreatePoolCapV2,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Public Functions ===

/// Reserves `SaleToken`'s pool creation with `create_pool_cap`, minted by the fresh LP coin `Lp`,
/// in a shared `PoolCreation` bound to `Issuer`, and returns the ticket for a sale of `SaleToken` in
/// `Quote` that migrates here. `Issuer` is the presale's package witness
/// (`blast_presale::blast_presale_package::PackageWitness`), passed as a type argument, so only a
/// `Migration` the presale sealed can consume the reservation; with the presale's one sale per
/// sale token, that binds the reservation to one sale. Framework and primitive types are rejected
/// because anyone can construct them. The pool's weights and fees are this module's constants, so
/// the sale carries no pool terms. The presale's `CreationPolicy` must admit `Venue`.
public fun prepare<Lp, SaleToken, Quote, Issuer>(
    _: &AdminCap,
    create_pool_cap: CreatePoolCapV2,
    ctx: &mut TxContext,
): VenueTicket<SaleToken, Quote> {
    let issuer = type_name::with_original_ids<Issuer>();
    assert!(!issuer.is_primitive(), EInvalidIssuer);
    let issuer_origin = type_name::original_id<Issuer>();
    assert!(issuer_origin != @0x1 && issuer_origin != @0x2, EInvalidIssuer);

    let pool_creation = PoolCreation<Lp, SaleToken> {
        id: object::new(ctx),
        issuer,
        create_pool_cap,
    };
    let pool_creation_id = object::id(&pool_creation);

    transfer::share_object(pool_creation);
    event::emit(PoolCreationReserved<Lp, SaleToken, Quote> { pool_creation_id, issuer });

    migration::issue_ticket(Venue())
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded sale prepared here: it redeems `migration`, the hand-off the
/// presale's own `migrate` returned earlier in the transaction, checks that the issuer `prepare`
/// pinned sealed its terms, consumes the sale token's `PoolCreation`, seeds a 50/50 Aftermath pool with all of the sale's tokens and Quote, wraps it in
/// a DAO-fee pool paying the treasury, shares that pool, sends its owner cap to the treasury, and
/// locks the LP at `BURN_ADDRESS`. No vault is created, so the
/// hand-off's vault terms are dropped after naming the sale in the event.
#[allow(lint(share_owned))]
public fun migrate<Lp, SaleToken, Quote>(
    migration: Migration<SaleToken, Quote>,
    pool_creation: PoolCreation<Lp, SaleToken>,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    let (tokens, quote, terms) = migration.redeem(Venue());
    assert!(terms.package_witness() == pool_creation.issuer, EWrongIssuer);
    let (token_amount, quote_amount) = (tokens.value(), quote.value());

    let PoolCreation { id, issuer: _, create_pool_cap } = pool_creation;
    id.delete();

    let (pool, lp) = if (sorts_before<SaleToken, Quote>()) {
        create_pool<Lp, _, _>(
            create_pool_cap,
            pool_registry,
            tokens.into_coin(ctx),
            quote.into_coin(ctx),
            ctx,
        )
    } else {
        create_pool<Lp, _, _>(
            create_pool_cap,
            pool_registry,
            quote.into_coin(ctx),
            tokens.into_coin(ctx),
            ctx,
        )
    };
    assert_pool_balances!(
        pool.balance_of<Lp, SaleToken>(),
        token_amount,
        pool.balance_of<Lp, Quote>(),
        quote_amount,
    );

    let pool_id = object::id(&pool);
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        DAO_FEE_BPS,
        TREASURY,
        ctx,
    );
    assert_dao_fee_terms!(
        dao_fee_pool.fee_bps(),
        DAO_FEE_BPS,
        dao_fee_pool.fee_recipient(),
        TREASURY,
    );

    event::emit(Migrated<Lp, SaleToken, Quote> {
        presale_id: terms.origin(),
        pool_id,
        dao_fee_pool_id: object::id(&dao_fee_pool),
        owner_cap_id: object::id(&owner_cap),
        lp_coin_id: object::id(&lp),
        lp: lp.value(),
    });

    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(owner_cap, TREASURY);
    transfer::public_transfer(lp, BURN_ADDRESS);
}

// === Private Functions ===

// Lazy arguments preserve short-circuit order for the external reads.
macro fun assert_pool_balances(
    $actual_meme: u64,
    $expected_meme: u64,
    $actual_quote: u64,
    $expected_quote: u64
) {
    assert!($actual_meme == $expected_meme && $actual_quote == $expected_quote, EPoolMismatch);
}

macro fun assert_dao_fee_terms(
    $actual_bps: u16,
    $expected_bps: u16,
    $actual_recipient: address,
    $expected_recipient: address
) {
    assert!(
        $actual_bps == $expected_bps && $actual_recipient == $expected_recipient,
        EDaoFeePoolMismatch
    );
}

/// Creates the 50/50 pool from both coins, which must be in Aftermath's coin order.
fun create_pool<Lp, Coin1, Coin2>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    coin_1: Coin<Coin1>,
    coin_2: Coin<Coin2>,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    pool_factory::create_pool_2_coins_v2(
        create_pool_cap,
        pool_registry,
        POOL_NAME,
        vector[HALF_WEIGHT, HALF_WEIGHT],
        FLATNESS,
        vector[BASE_SWAP_FEE, BASE_SWAP_FEE],
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

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
/// The `PoolCreationReserved` payload with this field, for comparing emitted events.
public fun pool_creation_reserved_for_testing<Lp, SaleToken, Quote>(
    pool_creation_id: ID,
    issuer: TypeName,
): PoolCreationReserved<Lp, SaleToken, Quote> {
    PoolCreationReserved { pool_creation_id, issuer }
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

/// `prepare` reserved the sale token `SaleToken`'s Aftermath pool creation for the LP coin `Lp` in
/// the shared `pool_creation_id`, which only a migration whose terms `issuer` sealed consumes.
public struct PoolCreationReserved<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    pool_creation_id: ID,
    issuer: TypeName,
}

/// The sale `presale_id` migrated into the Aftermath pool `pool_id`, which traders reach through
/// the shared DAO-fee pool `dao_fee_pool_id`. The treasury holds that pool's owner cap
/// `owner_cap_id`, and `BURN_ADDRESS` holds the LP coin `lp_coin_id`, which locks the sale's `lp`
/// units forever.
public struct Migrated<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
    lp_coin_id: ID,
    lp: u64,
}

// === Constants ===

/// The partner treasury: receives every pool's DAO fees and owner cap.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;

/// Owns every pool's LP coin. No one can sign for the zero address, so nothing it owns can ever
/// be used in a transaction again.
const BURN_ADDRESS: address = @0x0;

/// The DAO fee, 2%, that Aftermath sends to the treasury from every swap, deposit, and withdrawal
/// until the owner cap changes it.
const DAO_FEE_BPS: u16 = 200;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked LP.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this package's fee and pay the treasury.";

#[error(code = 2)]
const EInvalidIssuer: vector<u8> = b"The issuer must not be a primitive or framework type.";

#[error(code = 3)]
const EWrongIssuer: vector<u8> = b"The migration's terms must be sealed by the issuer the pool creation pinned.";

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_core::migration::{Self, Migration, VenueTicket};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name::{Self, TypeName};

use sui::{coin::Coin, event};
