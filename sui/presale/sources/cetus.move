// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Cetus sale-token preparation, permissionless migration into `blast_vault` custody, and LP-fee
/// collection for presales.
///
/// Preparing the sale token mints its single Cetus `PoolCreationCap` from the treasury capability
/// before any supply exists, registers the pair at the creator's tick spacing, and returns the
/// `VenueTicket` the presale redeems; afterwards only that capability or Cetus's pool-manager role
/// can create the pair's pool there. Migration redeems the sale's hand-off, creates and seeds the
/// pool, burns the full-range position through Cetus LP Burn, and shares a vault holding the burn
/// proof under the sale's terms. Auto-LP and burn routes accrue in the vault until the shared
/// venues compound and buy back (ADR 0137, step 5).
module blast_presale::cetus;

// === Public Types ===

/// The Cetus venue's sealed witness: it issues tickets, redeems migrations, and keys the position
/// in the vault, so the creation policy and the vault registry admit this one type.
public struct Venue() has drop;

/// Key for a Meme type's reserved Cetus pool-creation capability.
public struct CreationCapKey<phantom Meme>() has copy, drop, store;

/// Transient dynamic-field name `cast` uses to retype a coin or balance.
public struct CastKey() has copy, drop, store;

// === Public Functions ===

/// Prepares `Meme` for a presale in `Quote` that migrates to a Cetus pool at `tick_spacing`, whose
/// fee rate Cetus derives from it, and returns the ticket `blast_presale::new` redeems. The pair's
/// pool creation is reserved at that tier before the supply is minted. Every sale token has one
/// sale, so the tier is recorded under its type.
public fun prepare<Meme, Quote>(
    package_version: &PackageVersion,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    treasury_cap: &mut TreasuryCap<Meme>,
    tick_spacing: u32,
    ctx: &mut TxContext,
): VenueTicket<Meme, Quote> {
    package_version.assert_current();

    let creation_cap = factory::mint_pool_creation_cap(cetus_config, pools, treasury_cap, ctx);
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        tick_spacing,
        &creation_cap,
        ctx,
    );
    venue_config.add_object(CreationCapKey<Meme>(), creation_cap);
    venue_config.add_pool_tier<Meme, Quote, _>(
        &Venue(),
        tick_spacing,
        config::get_fee_rate(tick_spacing, cetus_config),
    );

    migration::issue_ticket(Venue())
}

/// Anyone may migrate a funded presale into its reserved Cetus pool and a `blast_vault` vault.
/// `CoinA` and `CoinB` name the presale's Meme and Quote in Cetus's canonical coin order. The
/// vault holds the burn proof under the sale's terms, and Cetus's residuals wait in it for the
/// sale's owner.
public fun migrate<Meme, Quote, CoinA, CoinB>(
    sale: &mut Presale<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    registry: &VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(factory::is_right_order<CoinA, CoinB>(), blast_presale::errors::invalid_coin_order!());
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();

    let (tick_spacing, _) = venue_config.pool_tier<Meme>();
    let (meme, quote, terms) = sale
        .migrate(package_version, fee_policy, clock, ctx)
        .redeem(Venue());

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);
    let sqrt_price = migration_math::sqrt_price_x64(meme_amount, quote_amount, meme_is_a);
    let fix_coin_a = fixed_side_is_a(
        tick_lower,
        tick_upper,
        sqrt_price,
        meme_amount,
        quote_amount,
        meme_is_a,
    );

    let mut scratch = object::new(ctx);
    let (coin_a, coin_b) = scratch.cast_pair<_, _, Balance<CoinA>, Balance<CoinB>>(
        meme,
        quote,
        meme_is_a,
    );

    let (position, residual_a, residual_b) = pool_creator::create_pool_v3_with_creation_cap(
        cetus_config,
        pools,
        venue_config.pool_creation_cap<Meme>(),
        tick_spacing,
        sqrt_price,
        b"".to_string(),
        tick_lower,
        tick_upper,
        coin_a.into_coin(ctx),
        coin_b.into_coin(ctx),
        fix_coin_a,
        clock,
        ctx,
    );

    let (residual_meme, residual_quote) = scratch.cast_pair<_, _, Coin<Meme>, Coin<Quote>>(
        residual_a,
        residual_b,
        meme_is_a,
    );
    scratch.delete();

    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    let burn_proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);
    vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id, ctx)
        .share_with_position(
            &Venue(),
            treasury,
            burn_proof,
            liquidity,
            residual_meme.into_balance(),
            residual_quote.into_balance(),
            ctx,
        );
}

/// Anyone may collect LP fees from a migrated presale's Cetus position and split them through its
/// vault. `CoinA` and `CoinB` are the pool's coin order.
public fun collect_fees<Meme, Quote, CoinA, CoinB>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    assert!(vault.pool_id() == object::id(pool), blast_presale::errors::position_pool_mismatch!());

    let (fee_a, fee_b) = lp_burn::collect_fee(
        burn_manager,
        cetus_config,
        pool,
        vault.position_mut<_, _, _, CetusLPBurnProof>(&Venue(), vault_version),
        ctx,
    );

    let mut scratch = object::new(ctx);
    let (meme, quote) = scratch.cast_pair<_, _, Coin<Meme>, Coin<Quote>>(fee_a, fee_b, meme_is_a);
    scratch.delete();

    vault.split_fees(
        &Venue(),
        vault_version,
        treasury,
        currency,
        meme.into_balance(),
        quote.into_balance(),
        ctx,
    );
}

/// Anyone may collect every accrued position fee under the applied split, then activate the
/// vault's ready split. `CoinA` and `CoinB` are the pool's coin order.
public fun settle_and_apply_fee_split<Meme, Quote, CoinA, CoinB>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    vault.assert_fee_split_ready(clock);

    collect_fees(
        vault,
        package_version,
        vault_version,
        treasury,
        currency,
        cetus_config,
        burn_manager,
        pool,
        ctx,
    );

    vault.apply_fee_split(&Venue(), vault_version, clock);
}

// === Private Functions ===

/// Whether Meme is `CoinA`, after proving `(CoinA, CoinB)` is exactly the presale's pair.
fun meme_is_coin_a<Meme, Quote, CoinA, CoinB>(): bool {
    assert_coin_pair<Meme, Quote, CoinA, CoinB>();

    type_name::with_original_ids<Meme>() == type_name::with_original_ids<CoinA>()
}

/// Aborts unless `(CoinA, CoinB)` is exactly the presale's Meme and Quote, in either order.
fun assert_coin_pair<Meme, Quote, CoinA, CoinB>() {
    let (meme, quote) = (
        type_name::with_original_ids<Meme>(),
        type_name::with_original_ids<Quote>(),
    );
    let (coin_a, coin_b) = (
        type_name::with_original_ids<CoinA>(),
        type_name::with_original_ids<CoinB>(),
    );
    assert!(
        (meme == coin_a && quote == coin_b) || (meme == coin_b && quote == coin_a),
        blast_presale::errors::wrong_coin_pair!(),
    );
}

/// Chooses the side to fix, preferring the side with more atoms, Meme on a tie: a full-range
/// position needs slightly more of the other side than the seed ratio, so that partner balance
/// covers it. When both sides are nearly equal, rounding can still overdraw by one atom, so
/// Cetus's own math decides and the other side is fixed instead. Any tick inside the full range
/// selects Cetus's in-range branch; pool creation aborts anyway if the seed price lies outside it.
fun fixed_side_is_a(
    tick_lower: u32,
    tick_upper: u32,
    sqrt_price: u128,
    meme_amount: u64,
    quote_amount: u64,
    meme_is_a: bool,
): bool {
    let (amount_a, amount_b) = if (meme_is_a) (meme_amount, quote_amount) else (
        quote_amount,
        meme_amount,
    );
    let prefer_a = (meme_amount >= quote_amount) == meme_is_a;
    let (_, needed_a, needed_b) = clmm_math::get_liquidity_by_amount(
        i32::from_u32(tick_lower),
        i32::from_u32(tick_upper),
        i32::zero(),
        sqrt_price,
        if (prefer_a) amount_a else amount_b,
        prefer_a,
    );

    if (needed_a <= amount_a && needed_b <= amount_b) prefer_a else !prefer_a
}

/// Retypes `value` as `To` through a dynamic field on `scratch`. Removal succeeds only under the
/// stored type, so this aborts unless `From` and `To` are the same type; `meme_is_coin_a` has
/// already proven that for every call.
fun cast<From: store, To: store>(scratch: &mut UID, value: From): To {
    scratch.add_dynamic_field(CastKey(), value);
    scratch.remove_dynamic_field(CastKey())
}

/// Retypes a Meme-and-Quote pair into Cetus's coin order, or a coin-order pair back, through
/// `scratch`: in place when Meme is coin A, crossed otherwise.
fun cast_pair<First: store, Second: store, ToFirst: store, ToSecond: store>(
    scratch: &mut UID,
    first: First,
    second: Second,
    meme_is_a: bool,
): (ToFirst, ToSecond) {
    if (meme_is_a) (scratch.cast(first), scratch.cast(second)) else (
        scratch.cast(second),
        scratch.cast(first),
    )
}

fun pool_creation_cap<Meme>(self: &VenueConfig): &PoolCreationCap {
    self.object(CreationCapKey<Meme>())
}

// === Test-Only Functions ===

#[test_only]
public fun meme_is_coin_a_for_testing<Meme, Quote, CoinA, CoinB>(): bool {
    meme_is_coin_a<Meme, Quote, CoinA, CoinB>()
}

#[test_only]
public fun assert_coin_pair_for_testing<Meme, Quote, CoinA, CoinB>() {
    assert_coin_pair<Meme, Quote, CoinA, CoinB>()
}

#[test_only]
public fun cast_for_testing<From: store, To: store>(scratch: &mut UID, value: From): To {
    scratch.cast(value)
}

#[test_only]
/// A ticket for the pair, as `prepare` returns after reserving the pool: the Cetus link stubs
/// cannot reserve one in unit tests.
public fun ticket_for_testing<Meme, Quote>(): VenueTicket<Meme, Quote> {
    migration::issue_ticket(Venue())
}

#[test_only]
/// Runs `migrate`'s redemption and vault creation with `position` in place of the burn proof,
/// keeping the whole hand-off as the owner's residuals: the Cetus link stubs cannot create a pool
/// in unit tests. Returns the vault's ID.
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

// === Imports ===

use blast_admin::package_version::PackageVersion as VaultVersion;

use blast_core::{blast_treasury::Treasury, migration::{Self, VenueTicket}};

use blast_presale::{
    blast_presale::Presale,
    blast_presale_package::PackageVersion,
    fee_policy::FeePolicy,
    migration_math,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use cetus_clmm::{
    clmm_math,
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::Pool,
    pool_creator
};

use integer_mate::i32;

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use std::type_name;

use sui::{
    balance::Balance,
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    dynamic_field
};

use fun cast as UID.cast;

use fun cast_pair as UID.cast_pair;

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::remove as UID.remove_dynamic_field;

use fun pool_creation_cap as VenueConfig.pool_creation_cap;
