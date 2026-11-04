// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Bluefin sale-token preparation, permissionless migration into `blast_vault` custody, and LP-fee
/// collection for presales. Auto-LP and burn routes accrue in the vault until the shared venues
/// compound and buy back (ADR 0137, step 5).
module blast_presale::bluefin;

// === Public Types ===

/// The Bluefin venue's sealed witness: it issues tickets, redeems migrations, and keys the
/// position in the vault, so the creation policy and the vault registry admit this one type.
public struct Venue() has drop;

// === Public Functions ===

/// Prepares `Meme` for a presale in `Quote` that migrates to a Bluefin pool at this tier, and
/// returns the ticket `blast_presale::new` redeems. Every sale token has one sale, so the tier is
/// recorded under its type; the treasury capability proves the caller controls the token, so no
/// one else can record its tier first.
public fun prepare<Meme, Quote>(
    package_version: &PackageVersion,
    venue_config: &mut VenueConfig,
    _: &TreasuryCap<Meme>,
    currency: &Currency<Meme>,
    tick_spacing: u32,
    pool_fee_rate: u64,
): VenueTicket<Meme, Quote> {
    package_version.assert_current();

    assert!(
        tick_spacing > 0
            && tick_spacing <= constants::bluefin_max_tick_spacing!()
            && pool_fee_rate > 0
            && pool_fee_rate <= constants::bluefin_max_fee_rate!(),
        blast_presale::errors::invalid_tier!(),
    );
    assert!(
        currency.symbol().length() <= constants::max_meme_symbol_length!(),
        blast_presale::errors::symbol_too_long!(),
    );

    venue_config.add_pool_tier<Meme, Quote, _>(&Venue(), tick_spacing, pool_fee_rate);

    migration::issue_ticket(Venue())
}

/// Anyone may atomically migrate a funded presale into its configured Bluefin pool and a
/// `blast_vault` vault holding the position under the sale's terms; Bluefin's residuals wait in
/// it for the sale's owner.
public fun migrate<Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    venue_config: &VenueConfig,
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    registry: &VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let (tick_spacing, pool_fee_rate) = venue_config.pool_tier<Meme>();
    let (meme, quote, terms) = sale
        .migrate(package_version, fee_policy, clock, ctx)
        .redeem(Venue());

    let source_meme = meme.value();
    let source_quote = quote.value();
    let (lower_tick, upper_tick) = bluefin_config.full_range(tick_spacing);

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        currency.pool_name(quote_currency),
        b"",
        currency.symbol().into_bytes(),
        currency.decimals(),
        b"",
        quote_currency.symbol().into_bytes(),
        quote_currency.decimals(),
        quote_currency.icon_url().into_bytes(),
        tick_spacing,
        pool_fee_rate,
        migration_math::sqrt_price_x64(source_meme, source_quote, true),
        creation_fee.into_balance(),
        ctx,
    );

    let mut position = pool::open_position(
        bluefin_config,
        &mut pool,
        lower_tick.as_u32(),
        upper_tick.as_u32(),
        ctx,
    );
    let fix_meme = pool.fixes_meme(lower_tick, upper_tick, source_meme, source_quote);
    let (_, _, residual_meme, residual_quote) = pool::add_liquidity_with_fixed_amount(
        clock,
        bluefin_config,
        &mut pool,
        &mut position,
        meme,
        quote,
        if (fix_meme) source_meme else source_quote,
        fix_meme,
    );

    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id, ctx)
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

/// Anyone may collect LP fees from a migrated presale's Bluefin position and split them through
/// its vault.
public fun collect_fees<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(vault.pool_id() == object::id(pool), blast_presale::errors::position_pool_mismatch!());

    let (_, _, meme, quote) = pool::collect_fee(
        clock,
        bluefin_config,
        pool,
        vault.position_mut<_, _, _, Position>(&Venue(), vault_version),
    );

    vault.split_fees(&Venue(), vault_version, treasury, currency, meme, quote, ctx);
}

/// Anyone may collect every accrued position fee under the applied split, then activate the
/// vault's ready split. Readiness alone never changes collection accounting.
public fun settle_and_apply_fee_split<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
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
        bluefin_config,
        pool,
        clock,
        ctx,
    );

    vault.apply_fee_split(&Venue(), vault_version, clock);
}

// === Private Functions ===

/// The full tick range, with both bounds aligned inward to the pool's tick spacing.
fun full_range(bluefin_config: &GlobalConfig, tick_spacing: u32): (I32, I32) {
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);

    (minimum_tick.div(spacing).mul(spacing), maximum_tick.div(spacing).mul(spacing))
}

/// The pool name, `<Meme symbol>-<Quote symbol>`.
fun pool_name<Meme, Quote>(
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
): vector<u8> {
    let mut name = currency.symbol().into_bytes();
    name.append(b"-");
    name.append(quote_currency.symbol().into_bytes());
    name
}

/// Whether to fix the Meme side when seeding. Fix the side with more atoms: a full-range position
/// needs slightly more of the other side than the seed ratio, so that partner balance covers it.
/// When both sides are nearly equal, rounding can still overdraw by one atom, so ask Bluefin's own
/// math and fix the other side.
fun fixes_meme<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    lower_tick: I32,
    upper_tick: I32,
    source_meme: u64,
    source_quote: u64,
): bool {
    let prefer_meme = source_meme >= source_quote;
    let (_, needed_meme, needed_quote) = pool::get_liquidity_by_amount(
        lower_tick,
        upper_tick,
        pool.current_tick_index(),
        pool.current_sqrt_price(),
        if (prefer_meme) source_meme else source_quote,
        prefer_meme,
    );

    if (needed_meme <= source_meme && needed_quote <= source_quote) prefer_meme else !prefer_meme
}

// === Test-Only Functions ===

#[test_only]
/// Runs `migrate`'s redemption and vault creation with `position` in place of the pool's, keeping
/// the whole hand-off as the owner's residuals: the Bluefin link stubs cannot create a pool in unit
/// tests. Returns the vault's ID.
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
    constants,
    fee_policy::FeePolicy,
    migration_math,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32::{Self, I32};

use sui::{clock::Clock, coin::{Coin, TreasuryCap}, coin_registry::Currency, sui::SUI};

use fun fixes_meme as Pool.fixes_meme;

use fun full_range as GlobalConfig.full_range;

use fun pool_name as Currency.pool_name;
