// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Bluefin coin preparation, migration into `blast_vault` custody, fee collection with auto-LP,
/// settled fee-split updates, and buybacks over custodied concentrated-liquidity principal.
///
/// Bluefin pools are keyed by their exact type-parameter order, so this module
/// always creates and expects `Pool<Meme, Quote>` with Meme as coin A.
module blast_fun_migrators::bluefin;

// === Public Types ===

/// The Bluefin venue's sealed witness: it issues tickets, redeems migrations, and keys the position
/// in the vault, so a launch and the vault registry admit this one type.
public struct Venue() has drop;

/// A prepared coin's Bluefin pool tier.
public struct PoolTier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// Sealed `VenueConfig` field name for the Meme type's Bluefin pool tier.
public struct PoolTierKey<phantom Meme>() has copy, drop, store;

// === Public Functions ===

/// Prepares `Meme` for a Bluefin launch in `Quote` at the creator's tier, recording the tier, and
/// returns the ticket `launch::new` redeems. `treasury_cap` proves the caller controls the coin,
/// so no one else can record its tier first.
///
/// Bluefin checks the tier only when migration creates the pool, and a launch cannot change its
/// tier, so the same bounds apply here first.
public fun prepare<Meme, Quote>(
    migrators_version: &MigratorsVersion,
    venue_config: &mut VenueConfig,
    _: &TreasuryCap<Meme>,
    tick_spacing: u32,
    fee_rate: u64,
): VenueTicket<Meme, Quote> {
    migrators_version.assert_current();
    assert!(
        tick_spacing > 0 && tick_spacing <= constants::bluefin_max_tick_spacing!() && fee_rate > 0
            && fee_rate <= constants::bluefin_max_fee_rate!(),
        EInvalidTier,
    );

    venue_config.add_value(PoolTierKey<Meme>(), PoolTier { tick_spacing, fee_rate });

    blast_events::bluefin_pool_tier_recorded<Meme, Quote>(tick_spacing, fee_rate);

    migration::issue_ticket(Venue())
}

/// Migrates a MigrationReady launch into a new full-range pool at the recorded tier and a
/// `blast_vault` vault.
///
/// Redeems the launch's hand-off. The opening price derives from the handed-off balances, which
/// seed the position on the side `is_meme_seed_side` chooses. `creation_fee` is paid whole, and
/// Bluefin aborts unless it is exactly the configured SUI fee. The position and the venue
/// residuals go to the vault, which has no withdrawal path. The caller receives no object; Bluefin
/// records it as the new pool's manager, a role limited to the pool's reward emissions and to
/// handing the role on (ADR 0088).
public fun migrate<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &blast_admin::package_version::PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    currency: &mut Currency<Meme>,
    quote_currency: &Currency<Quote>,
    venue_config: &VenueConfig,
    bluefin_config: &mut GlobalConfig,
    registry: &mut VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    let PoolTier { tick_spacing, fee_rate } = *venue_config.value(PoolTierKey<Meme>());
    let (lower_tick, upper_tick) = bluefin_config.full_range_tick_range(tick_spacing);
    let (meme, quote, terms) = launch
        .migrate(package_version, config, currency, ctx)
        .redeem(Venue());

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        currency.pool_name(quote_currency),
        // No Meme icon, as Cetus: the metadata capability can grow the icon URL, and the position
        // stores it, so a long URL would make the position too large to create.
        b"",
        currency.symbol().into_bytes(),
        currency.decimals(),
        b"",
        quote_currency.symbol().into_bytes(),
        quote_currency.decimals(),
        quote_currency.icon_url().into_bytes(),
        tick_spacing,
        fee_rate,
        migration_math::sqrt_price_x64(meme.value(), quote.value(), true),
        creation_fee.into_balance(),
        ctx,
    );
    let mut position = pool::open_position(bluefin_config, &mut pool, lower_tick, upper_tick, ctx);
    let (residual_meme, residual_quote) = pool.seed(
        bluefin_config,
        &mut position,
        meme,
        quote,
        clock,
    );

    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id)
        .share_with_position(
            &Venue(),
            treasury,
            position,
            liquidity,
            residual_meme,
            residual_quote,
            ctx,
        );
    pool.share_pool_object();
}

/// Collects the custodied position's fees, splits them, burns the burn share's Meme, and adds the
/// auto-LP share back to the position. Anyone may call it.
public fun collect_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();

    self.settle_fees(vault_version, treasury, currency, bluefin_config, pool, clock, ctx);
}

/// Anyone may settle accrued fees under the current split, then apply the stored ready proposal.
public fun settle_and_apply_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    self.assert_fee_split_ready(clock);

    self.settle_fees(vault_version, treasury, currency, bluefin_config, pool, clock, ctx);

    self.apply_fee_split(&Venue(), vault_version, clock);
}

/// Swaps `quote_in` of the vault's burn Quote for Meme in its pool and burns it, under a buyback
/// admin. Aborts unless `quote_in` is positive and at most the burn Quote held, and unless the swap
/// returns at least `min_meme_out`; the admin sets it from an off-chain price, since anyone can move
/// the pool's price within a transaction. Quote the pool does not take stays for the next buyback.
public fun buyback_and_burn<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    quote_in: u64,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (quote, receipt) = self.take_buyback_quote(&Venue(), admin_witness, vault_version, quote_in);
    let (meme, quote) = pool::swap(
        clock,
        bluefin_config,
        pool,
        balance::zero(),
        quote,
        false,
        true,
        quote_in,
        0,
        constants::max_swap_sqrt_price!(),
    );

    self.burn_buyback(&Venue(), vault_version, receipt, currency, meme, quote, min_meme_out, ctx);
}

// === Private Functions ===

/// Aligns Bluefin's configured tick bounds to `tick_spacing`, giving the widest range a position
/// at that spacing can open.
fun full_range_tick_range(bluefin_config: &GlobalConfig, tick_spacing: u32): (u32, u32) {
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);

    (
        minimum_tick.div(spacing).mul(spacing).as_u32(),
        maximum_tick.div(spacing).mul(spacing).as_u32(),
    )
}

/// Names the pool by the two coin symbols around a one-byte separator.
fun pool_name<Meme, Quote>(
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
): vector<u8> {
    let mut name = currency.symbol().into_bytes();
    name.append(b"-");
    name.append(quote_currency.symbol().into_bytes());

    name
}

/// Adds the handed-off balances to the new full-range position, fixing the side
/// `is_meme_seed_side` chooses, and returns the residuals.
fun seed<Meme, Quote>(
    pool: &mut Pool<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    position: &mut Position,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    clock: &Clock,
): (Balance<Meme>, Balance<Quote>) {
    let fix_meme = pool.is_meme_seed_side(position, meme.value(), quote.value());
    let fixed_amount = if (fix_meme) meme.value() else quote.value();
    let (_, _, residual_meme, residual_quote) = pool::add_liquidity_with_fixed_amount(
        clock,
        bluefin_config,
        pool,
        position,
        meme,
        quote,
        fixed_amount,
        fix_meme,
    );

    (residual_meme, residual_quote)
}

/// Whether Meme is the side the migration seed fixes, preferring the side with more atoms: a
/// full-range position needs slightly more of the other side than the seed ratio, so that partner
/// balance covers it. When both sides are nearly equal, rounding can still overdraw by one atom, so
/// Bluefin's own math decides and the other side is fixed instead.
fun is_meme_seed_side<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    position: &Position,
    meme_amount: u64,
    quote_amount: u64,
): bool {
    let prefer_meme = meme_amount >= quote_amount;
    let (_, needed_meme, needed_quote) = pool::get_liquidity_by_amount(
        position.lower_tick(),
        position.upper_tick(),
        pool.current_tick_index(),
        pool.current_sqrt_price(),
        if (prefer_meme) meme_amount else quote_amount,
        prefer_meme,
    );

    migration_math::seed_fixed_side(
        prefer_meme,
        meme_amount,
        quote_amount,
        needed_meme,
        needed_quote,
    )
}

/// Collects the position's fees, splits them through the vault, and adds the auto-LP share back.
fun settle_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme_fee, quote_fee) = self.collect_position_fees(vault_version, bluefin_config, pool, clock);
    self.split_fees(&Venue(), vault_version, treasury, currency, meme_fee, quote_fee, ctx);
    self.compound(vault_version, bluefin_config, pool, clock);
}

/// Collects the attached position's fees from `pool`, which must be the position's own pool.
fun collect_position_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
): (Balance<Meme>, Balance<Quote>) {
    let position = self.position_mut<_, _, _, Position>(&Venue(), vault_version);
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (_, _, meme_fee, quote_fee) = pool::collect_fee(clock, bluefin_config, pool, position);

    (meme_fee, quote_fee)
}

/// Adds as much of the waiting auto-LP balances as the position takes at the pool's current price,
/// fixing the side the other can cover from the pool's and the position's bound sqrt prices, and
/// keeps the rest for the next call. `collect_position_fees` already matched the pool.
fun compound<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
) {
    let (meme, quote, receipt) = self.take_auto_lp(&Venue(), vault_version);
    let position = self.position_mut<_, _, _, Position>(&Venue(), vault_version);
    let (fix_meme, fixed_amount) = pool.fixed_side(position, meme.value(), quote.value());

    let (_, _, meme, quote) = if (fixed_amount > 0) {
        pool::add_liquidity_with_fixed_amount(
            clock,
            bluefin_config,
            pool,
            position,
            meme,
            quote,
            fixed_amount,
            fix_meme,
        )
    } else {
        (0, 0, meme, quote)
    };

    self.keep_auto_lp(&Venue(), vault_version, receipt, meme, quote);
}

/// Chooses the side an auto-LP add fixes, and how much, from the pool's price and the position's
/// bound sqrt prices; a zero amount means nothing can be added now.
fun fixed_side<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    position: &Position,
    meme_amount: u64,
    quote_amount: u64,
): (bool, u64) {
    let ticks = pool.get_tick_manager();
    let sqrt_lower = ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();
    let sqrt_upper = ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();

    migration_math::auto_lp_fixed_side(
        sqrt_lower,
        pool.current_sqrt_price(),
        sqrt_upper,
        meme_amount,
        quote_amount,
    )
}

// === Errors ===

#[error(code = 0)]
const EPositionPoolMismatch: vector<u8> = b"Custodied position must belong to the supplied pool.";

#[error(code = 1)]
const EInvalidTier: vector<u8> = b"Bluefin tier needs a tick spacing in 1..=400 and a fee rate in 1..=20,000.";

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion as VaultVersion};

use blast_core::{
    blast_domain::BuybackAdmin,
    blast_treasury::Treasury,
    migration::{Self, VenueTicket}
};

use blast_fun::{blast_fun::BLAST_FUN, launch::Launch, launch_config::LaunchConfig};

use blast_fun_migrators::{
    blast_events,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
    constants,
    migration_math,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    sui::SUI
};

use fun collect_position_fees as Vault.collect_position_fees;
use fun compound as Vault.compound;
use fun settle_fees as Vault.settle_fees;

use fun fixed_side as Pool.fixed_side;

use fun full_range_tick_range as GlobalConfig.full_range_tick_range;

use fun is_meme_seed_side as Pool.is_meme_seed_side;

use fun pool_name as Currency.pool_name;

use fun seed as Pool.seed;
