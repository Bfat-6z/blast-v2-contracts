// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Bluefin preparation: the tier and symbol bounds and their order, the write-once tier record,
/// its event, and the ticket it issues; the venue's vault-registry admission; and the auto-LP side
/// selection, checked against an independent Q64.64 oracle of the Uniswap v3 liquidity formulas. The venue interface is an `abort 0` link stub, so
/// migration, collection with auto-LP, settled fee-split updates, and buybacks are proven in the
/// PTB venue-fork tests instead.
module blast_migrators::bluefin_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated coin package's.
public struct BLUEFIN_TESTS() has drop;

public struct QUOTE() has drop;

/// Everything `bluefin::prepare` reads, for one coin.
public struct PrepareFixture {
    scenario: Scenario,
    migrators_version: PackageVersion<BLAST_MIGRATORS>,
    venue_config: VenueConfig,
    treasury_cap: TreasuryCap<BLUEFIN_TESTS>,
    currency: Currency<BLUEFIN_TESTS>,
}

// === Tests ===

#[test]
fun seed_keeps_the_preferred_side_when_both_balances_cover_the_venue_quote() {
    assert!(bluefin::seed_fixed_side_for_testing(true, 10, 20, 10, 20));
    assert!(!bluefin::seed_fixed_side_for_testing(false, 10, 20, 10, 19));
}

#[test]
fun seed_flips_the_preferred_side_on_one_atom_of_rounding_overdraw() {
    assert!(bluefin::seed_fixed_side_for_testing(false, 10, 20, 11, 20));
    assert!(!bluefin::seed_fixed_side_for_testing(true, 10, 20, 10, 21));
}

#[test]
fun prepare_issues_a_bluefin_ticket_at_the_smallest_tier() {
    let mut f = start(b"MEME");

    let venue = f.prepare(1, 1).redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<Venue>());
    f.end();
}

#[test]
fun prepare_accepts_the_largest_bluefin_tier_and_symbol() {
    let mut f = start(symbol_of_length(32));

    let venue = f.prepare(400, 20_000).redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<Venue>());
    f.end();
}

#[test]
/// The pair's tier is the one event preparation emits, typed by the pair.
fun prepare_records_the_pairs_tier_in_one_event() {
    let mut f = start(b"MEME");

    f.prepare(60, 2_500).redeem_ticket();

    assert_eq!(
        event::events_by_type<BluefinPoolTierRecorded<BLUEFIN_TESTS, QUOTE>>(),
        vector[events::bluefin_pool_tier_recorded_for_testing(60, 2_500)],
    );
    f.end();
}

#[test, expected_failure(
    abort_code = sui::dynamic_field::EFieldAlreadyExists,
    location = sui::dynamic_field,
)]
fun prepare_records_one_tier_per_coin() {
    let mut f = start(b"MEME");
    f.prepare(200, 10_000).redeem_ticket();

    f.prepare(60, 2_500).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::EInvalidTier,
    location = blast_migrators::bluefin,
)]
fun prepare_rejects_a_zero_tick_spacing() {
    let mut f = start(b"MEME");

    f.prepare(0, 10_000).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::EInvalidTier,
    location = blast_migrators::bluefin,
)]
fun prepare_rejects_a_tick_spacing_above_the_bluefin_bound() {
    let mut f = start(b"MEME");

    f.prepare(401, 10_000).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::EInvalidTier,
    location = blast_migrators::bluefin,
)]
fun prepare_rejects_a_zero_fee_rate() {
    let mut f = start(b"MEME");

    f.prepare(200, 0).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::EInvalidTier,
    location = blast_migrators::bluefin,
)]
fun prepare_rejects_a_fee_rate_above_the_bluefin_bound() {
    let mut f = start(b"MEME");

    f.prepare(200, 20_001).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::ESymbolTooLong,
    location = blast_migrators::bluefin,
)]
fun prepare_rejects_a_symbol_above_32_bytes() {
    let mut f = start(symbol_of_length(33));

    f.prepare(200, 10_000).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_migrators::errors::EInvalidTier,
    location = blast_migrators::bluefin,
)]
fun prepare_checks_the_tier_before_the_symbol() {
    let mut f = start(symbol_of_length(33));

    f.prepare(0, 0).redeem_ticket();

    abort
}

#[test, expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::package_version,
)]
fun prepare_checks_the_migrators_generation_before_the_tier() {
    let mut f = start(symbol_of_length(33));
    f.migrators_version.set_generation_for_testing(2);

    f.prepare(0, 0).redeem_ticket();

    abort
}

#[test]
/// The vault registry admits the Bluefin venue's witness at its publication notice of zero.
fun the_vault_registry_admits_the_bluefin_venue() {
    let mut ctx = tx_context::dummy();
    let mut registry = blast_vault_package::empty_registry_for_testing(&mut ctx);
    let vault_version = blast_vault_package::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();

    registry.schedule_witness<Venue>(&admin, &vault_version, &clock);
    registry.apply_witness<Venue>(&vault_version, &clock);

    let admitted = event::events_by_type<SetApplied<WitnessesKey, TypeName>>().map!(|applied| {
        let (_, _, change, _) = applied.set_applied_fields();
        change.member().destroy_some()
    });
    assert_eq!(admitted, vector[type_name::with_original_ids<Venue>()]);
    destroy(registry);
    destroy(vault_version);
    clock.destroy_for_testing();
}

// Auto-LP Side Selection

#[test]
fun balanced_amounts_with_room_for_the_margin_fix_coin_a() {
    // Price 1 in [0.25, 4]: each unit of A pairs with exactly one unit of B.
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 1_000_010, true, 1_000_000);
    assert_selects(
        MIN_SQRT_PRICE,
        ONE,
        MAX_SQRT_PRICE,
        1_000_000_000,
        2_000_000_000,
        true,
        1_000_000_000,
    );
}

#[test]
fun scarce_coin_b_is_fixed_instead() {
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_010, 1_000_000, false, 1_000_000);
    assert_selects(
        MIN_SQRT_PRICE,
        ONE,
        MAX_SQRT_PRICE,
        2_000_000_000,
        1_000_000_000,
        false,
        1_000_000_000,
    );
}

#[test]
fun amounts_without_room_for_the_margin_on_either_side_add_nothing() {
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 1, 1, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 2, 2, true, 0);
    assert_selects(MIN_SQRT_PRICE, ONE, MAX_SQRT_PRICE, 1_000_000_000, 1_000_000_000, true, 0);
}

#[test]
fun an_empty_side_adds_nothing() {
    assert_selects(ONE / 2, ONE, ONE * 2, 0, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 1_000_000, 0, true, 0);
    assert_selects(ONE / 2, ONE, ONE * 2, 0, 0, true, 0);
}

#[test]
fun a_price_on_or_outside_the_range_adds_nothing() {
    assert_selects(ONE / 2, ONE / 2, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE * 2, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE / 4, ONE * 2, 1_000_000, 1_000_000, true, 0);
    assert_selects(ONE / 2, ONE * 4, ONE * 2, 1_000_000, 1_000_000, true, 0);
}

#[test]
fun extreme_prices_and_u64_max_amounts_never_abort_and_the_other_side_always_fits() {
    let prices = vector[
        MIN_SQRT_PRICE + 1,
        MIN_SQRT_PRICE * 2,
        ONE,
        MAX_SQRT_PRICE / 2,
        MAX_SQRT_PRICE - 1,
    ];
    let amounts = vector[1, 3, 12_345, 1_000_000_000_000, U64_MAX - 2, U64_MAX];
    prices.do!(|price| {
        amounts.do_ref!(|amount_a| amounts.do_ref!(|amount_b| {
            assert_fits(MIN_SQRT_PRICE, price, MAX_SQRT_PRICE, *amount_a, *amount_b);
        }));
    });
    // Just below the upper bound nothing but coin B can be fixed, and all of it is used.
    assert_selects(
        MIN_SQRT_PRICE,
        MAX_SQRT_PRICE - 1,
        MAX_SQRT_PRICE,
        U64_MAX,
        U64_MAX,
        false,
        U64_MAX,
    );
    // Just above the lower bound coin A buys almost no B, so all of A is fixed.
    assert_selects(
        MIN_SQRT_PRICE,
        MIN_SQRT_PRICE + 1,
        MAX_SQRT_PRICE,
        U64_MAX,
        U64_MAX,
        true,
        U64_MAX,
    );
}

#[test]
fun every_selection_on_a_grid_fits_and_prefers_coin_a_whenever_it_fits() {
    let prices = vector[ONE / 2 + 1, ONE * 3 / 4, ONE, ONE * 3 / 2, ONE * 2 - 1];
    let amounts = vector[1, 2, 3, 5, 100, 1_000, 1_000_000, 1_000_000_000_000, U64_MAX];
    prices.do!(|price| {
        amounts.do_ref!(|amount_a| amounts.do_ref!(|amount_b| {
            assert_fits(ONE / 2, price, ONE * 2, *amount_a, *amount_b);
        }));
    });
}

// === Test Helpers ===

/// A fresh coin whose symbol is `symbol`, with a current migrators version and an empty venue
/// config.
fun start(symbol: vector<u8>): PrepareFixture {
    let mut scenario = test_scenario::begin(CREATOR);
    venue_config::init_for_testing(scenario.ctx());
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLUEFIN_TESTS>(),
        9,
        symbol.to_string(),
        b"Bluefin test coin".to_string(),
        b"".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let currency = coin_registry::unwrap_for_testing(initializer);
    let migrators_version = migrators_package::version_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let venue_config = scenario.take_shared<VenueConfig>();

    PrepareFixture { scenario, migrators_version, venue_config, treasury_cap, currency }
}

/// Prepares the fixture's coin for a Bluefin sale in `QUOTE` at the tier.
fun prepare(
    self: &mut PrepareFixture,
    tick_spacing: u32,
    fee_rate: u64,
): VenueTicket<BLUEFIN_TESTS, QUOTE> {
    bluefin::prepare(
        &self.migrators_version,
        &mut self.venue_config,
        &self.treasury_cap,
        &self.currency,
        tick_spacing,
        fee_rate,
    )
}

fun end(self: PrepareFixture) {
    let PrepareFixture { scenario, migrators_version, venue_config, treasury_cap, currency } = self;
    test_scenario::return_shared(venue_config);
    destroy(migrators_version);
    destroy(treasury_cap);
    destroy(currency);
    scenario.end();
}

/// An ASCII symbol of `length` bytes.
fun symbol_of_length(length: u64): vector<u8> {
    vector::tabulate!(length, |_| b"M"[0])
}

// Auto-LP oracle

/// Asserts the exact selection, then that it fits.
fun assert_selects(
    lower: u128,
    price: u128,
    upper: u128,
    amount_a: u64,
    amount_b: u64,
    expected_fix_a: bool,
    expected_amount: u64,
) {
    let (selected_fix_a, selected_amount) = bluefin::auto_lp_fixed_side_for_testing(
        lower,
        price,
        upper,
        amount_a,
        amount_b,
    );

    assert_eq!(selected_fix_a, expected_fix_a);
    assert_eq!(selected_amount, expected_amount);
    assert_fits(lower, price, upper, amount_a, amount_b);
}

/// Recomputes the chosen side's liquidity and the other side's rounded-up requirement with the
/// Uniswap v3 formulas and asserts the requirement plus the margin fits the other balance. Coin A
/// must be chosen whenever it fits, and nothing when the price is outside or a side is empty.
fun assert_fits(lower: u128, price: u128, upper: u128, amount_a: u64, amount_b: u64) {
    let (fix_a, fixed_amount) = bluefin::auto_lp_fixed_side_for_testing(
        lower,
        price,
        upper,
        amount_a,
        amount_b,
    );
    let (lower, price, upper) = (lower as u256, price as u256, upper as u256);
    let (available_a, available_b) = (amount_a as u256, amount_b as u256);
    let is_in_range = lower < price && price < upper && available_a > 0 && available_b > 0;
    let liquidity_a = if (is_in_range) liquidity_for_a(price, upper, available_a) else 0;
    let can_fix_a = liquidity_a > 0 && liquidity_a < (1 << 128)
        && amount_b_up(lower, price, liquidity_a) + MARGIN <= available_b;

    if (can_fix_a) {
        assert!(fix_a);
        assert_eq!(fixed_amount, amount_a);
    } else if (fixed_amount == 0) {
        assert!(fix_a);
    } else {
        assert!(is_in_range && !fix_a);
        assert_eq!(fixed_amount, amount_b);
        let liquidity_b = liquidity_for_b(lower, price, available_b);
        assert!(liquidity_b > 0);
        assert!(amount_a_up(price, upper, liquidity_b) + MARGIN <= available_a);
    };
}

/// `LiquidityAmounts.getLiquidityForAmount0` over [price, upper].
fun liquidity_for_a(price: u256, upper: u256, amount: u256): u256 {
    mul_div(amount, mul_div(price, upper, 1 << 64), upper - price)
}

/// `LiquidityAmounts.getLiquidityForAmount1` over [lower, price].
fun liquidity_for_b(lower: u256, price: u256, amount: u256): u256 {
    mul_div(amount, 1 << 64, price - lower)
}

/// `SqrtPriceMath.getAmount0Delta` over [price, upper], rounded up.
fun amount_a_up(price: u256, upper: u256, liquidity: u256): u256 {
    mul_div_up(liquidity << 64, upper - price, upper).div_ceil(price)
}

/// `SqrtPriceMath.getAmount1Delta` over [lower, price], rounded up.
fun amount_b_up(lower: u256, price: u256, liquidity: u256): u256 {
    mul_div_up(liquidity, price - lower, 1 << 64)
}

fun mul_div(x: u256, y: u256, divisor: u256): u256 {
    let (quotient, _) = mul_div_remainder(x, y, divisor);

    quotient
}

fun mul_div_up(x: u256, y: u256, divisor: u256): u256 {
    let (quotient, remainder) = mul_div_remainder(x, y, divisor);

    if (remainder > 0) quotient + 1 else quotient
}

/// Exact floor(x * y / divisor) and its remainder. A product wider than 256 bits is never formed:
/// the multiple of the divisor in `x` is scaled directly, and the rest is doubled and added over
/// the bits of `y` modulo the divisor. The divisor must be below 2^255.
fun mul_div_remainder(x: u256, y: u256, divisor: u256): (u256, u256) {
    if (x == 0 || y <= std::u256::max_value!() / x) return (x * y / divisor, x * y % divisor);
    let rest = x % divisor;
    let mut quotient = 0;
    let mut remainder = 0;
    let mut bit = 256u16;
    while (bit > 0) {
        bit = bit - 1;
        quotient = quotient * 2;
        remainder = remainder * 2;
        if (remainder >= divisor) {
            remainder = remainder - divisor;
            quotient = quotient + 1;
        };
        if ((y >> (bit as u8)) & 1 == 1) {
            remainder = remainder + rest;
            if (remainder >= divisor) {
                remainder = remainder - divisor;
                quotient = quotient + 1;
            };
        };
    };

    (x / divisor * y + quotient, remainder)
}

// === Constants ===

const CREATOR: address = @0xC0FFEE;

/// 1.0 in Q64.64.
const ONE: u128 = 1 << 64;

/// Cetus's and Bluefin's full-range sqrt-price bounds.
const MIN_SQRT_PRICE: u128 = 4_295_048_016;

const MAX_SQRT_PRICE: u128 = 79_226_673_515_401_279_992_447_579_055;

/// Atoms of the other asset the selection must leave unused beyond the exact requirement.
const MARGIN: u256 = 2;

const U64_MAX: u64 = 18_446_744_073_709_551_615;

// === Imports ===

use blast_admin::{blast_acl, delayed_set::SetApplied, package_version::PackageVersion};

use blast_core::{blast_domain::AdapterAdmin, migration::VenueTicket};

use blast_migrators::{
    blast_migrators::{Self as migrators_package, BLAST_MIGRATORS},
    bluefin::{Self, Venue},
    events::{Self, BluefinPoolTierRecorded},
    venue_config::{Self, VenueConfig}
};

use blast_vault::blast_vault_package::{Self, WitnessesKey};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{
    clock,
    coin::TreasuryCap,
    coin_registry::{Self, Currency},
    event,
    test_scenario::{Self, Scenario},
    test_utils
};
