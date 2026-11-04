// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Bluefin preparation: the tier bounds, the write-once tier record, the ticket it issues, and the
/// hand-off only Bluefin's witness redeems. The venue interface is an `abort 0` link stub, so
/// migration, collection with auto-LP, settled fee-split updates, and buybacks are proven on the
/// venue-fork harness instead.
module blast_fun_migrators::bluefin_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct BLUEFIN_TESTS has drop {}

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

/// A venue the fixture admits in place of Bluefin.
public struct OtherVenue() has drop;

// === Tests ===

#[test]
fun prepare_issues_a_bluefin_ticket_at_the_smallest_tier() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();

    let launch_id = f.open_bluefin_launch(1, 1);

    f.next_tx(launch_fixture::buyer());
    let launch = f.take_launch<BLUEFIN_TESTS, QUOTE>(launch_id);
    assert_eq!(launch.venue_for_testing(), type_name::with_original_ids<bluefin::Venue>());
    test_scenario::return_shared(launch);
    f.end();
}

#[test]
fun prepare_accepts_the_largest_bluefin_tier() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();

    let launch_id = f.open_bluefin_launch(400, 20_000);

    f.next_tx(launch_fixture::buyer());
    let launch = f.take_launch<BLUEFIN_TESTS, QUOTE>(launch_id);
    assert_eq!(launch.venue_for_testing(), type_name::with_original_ids<bluefin::Venue>());
    test_scenario::return_shared(launch);
    f.end();
}

#[test, expected_failure(
    abort_code = sui::dynamic_field::EFieldAlreadyExists,
    location = sui::dynamic_field,
)]
fun prepare_records_one_tier_per_coin() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();
    let treasury_cap = coin::create_treasury_cap_for_testing<BLUEFIN_TESTS>(f.ctx());
    let _ticket = f.prepare<QUOTE>(&treasury_cap, 200, 10_000);
    f.next_tx(launch_fixture::buyer());

    let _replacement = f.prepare<QUOTE>(&treasury_cap, 60, 2_500);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun prepare_rejects_a_zero_tick_spacing() {
    prepare_rejected_tier(0, 10_000)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun prepare_rejects_a_tick_spacing_above_the_bluefin_bound() {
    prepare_rejected_tier(401, 10_000)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun prepare_rejects_a_zero_fee_rate() {
    prepare_rejected_tier(200, 0)
}

#[test, expected_failure(
    abort_code = bluefin::EInvalidTier,
    location = blast_fun_migrators::bluefin,
)]
fun prepare_rejects_a_fee_rate_above_the_bluefin_bound() {
    prepare_rejected_tier(200, 20_001)
}

#[test, expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun prepare_checks_the_migrators_generation_before_the_tier() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();
    f.migrators_version_mut().set_for_testing(2);
    let treasury_cap = coin::create_treasury_cap_for_testing<BLUEFIN_TESTS>(f.ctx());

    let _ticket = f.prepare<QUOTE>(&treasury_cap, 0, 0);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EVenueNotAllowed,
    location = blast_fun::launch_config,
)]
fun a_bluefin_ticket_starts_no_launch_until_the_policy_admits_bluefin() {
    let mut f = launch_fixture::start<QUOTE, OtherVenue>();

    f.open_bluefin_launch(200, 10_000);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EQuoteNotAllowed,
    location = blast_fun::launch_config,
)]
fun a_bluefin_ticket_starts_a_launch_only_in_an_allowed_quote() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();
    let (ticket, treasury_cap) = f.new_ticket(
        test_utils::create_one_time_witness<BLUEFIN_TESTS>(),
        false,
    );
    let venue_ticket = f.prepare<OTHER_QUOTE>(&treasury_cap, 200, 10_000);

    f.open_launch(ticket, treasury_cap, venue_ticket, owner_split(), false);

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_core::errors::EWrongVenue,
    location = blast_core::migration,
)]
fun a_launch_prepared_at_bluefin_hands_off_only_to_bluefin() {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();
    let launch_id = f.open_bluefin_launch(200, 10_000);
    destroy(f.graduate<BLUEFIN_TESTS, QUOTE>(launch_id));

    f.next_tx(launch_fixture::buyer());
    let mut launch = f.take_launch<BLUEFIN_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<BLUEFIN_TESTS>();
    let (version, config, _, _, _, ctx) = f.migration_inputs();
    let (_meme, _quote, _terms) = launch
        .migrate(version, config, &mut currency, ctx)
        .redeem(OtherVenue());

    abort EUnexpectedSuccess
}

// === Test Helpers ===

/// Prepares a fresh coin at an out-of-bounds tier; preparation must abort.
fun prepare_rejected_tier(tick_spacing: u32, fee_rate: u64) {
    let mut f = launch_fixture::start<QUOTE, bluefin::Venue>();
    let treasury_cap = coin::create_treasury_cap_for_testing<BLUEFIN_TESTS>(f.ctx());

    let _ticket = f.prepare<QUOTE>(&treasury_cap, tick_spacing, fee_rate);

    abort EUnexpectedSuccess
}

/// Prepares the coin `treasury_cap` controls at the tier through the shared venue config.
fun prepare<Quote>(
    f: &LaunchFixture,
    treasury_cap: &TreasuryCap<BLUEFIN_TESTS>,
    tick_spacing: u32,
    fee_rate: u64,
): VenueTicket<BLUEFIN_TESTS, Quote> {
    let mut venue_config = f.take_venue_config();
    let venue_ticket = bluefin::prepare(
        f.migrators_version(),
        &mut venue_config,
        treasury_cap,
        tick_spacing,
        fee_rate,
    );
    test_scenario::return_shared(venue_config);

    venue_ticket
}

/// Mints the coin, prepares it at Bluefin at the tier, and opens its launch in `QUOTE`.
fun open_bluefin_launch(f: &mut LaunchFixture, tick_spacing: u32, fee_rate: u64): ID {
    let (ticket, treasury_cap) = f.new_ticket(
        test_utils::create_one_time_witness<BLUEFIN_TESTS>(),
        false,
    );
    let venue_ticket = f.prepare<QUOTE>(&treasury_cap, tick_spacing, fee_rate);

    f.open_launch(ticket, treasury_cap, venue_ticket, owner_split(), false)
}

fun owner_split(): FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Imports ===

use blast_core::{bps, fee_split::{Self, FeeSplit}, migration::VenueTicket};

use blast_fun_migrators::{bluefin, launch_fixture::{Self, LaunchFixture}};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{coin::{Self, TreasuryCap}, test_scenario, test_utils};

use fun open_bluefin_launch as LaunchFixture.open_bluefin_launch;
use fun prepare as LaunchFixture.prepare;
