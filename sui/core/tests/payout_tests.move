// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::payout_tests;

// === Constants ===

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

// === Tests ===

#[test]
fun an_outright_payout_sends_the_exact_amount_and_keeps_the_rest() {
    let mut scenario = test_scenario::begin(ALICE);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut funds = balance::create_for_testing<SUI>(100);

    let recipient = payout::recipient(BOB, option::none());
    assert_eq!(recipient.destination(), BOB);

    let schedule = payout::pay_or_vest(&mut funds, 40, &recipient, &clock, scenario.ctx());
    assert!(schedule.is_none());
    assert_eq!(funds.value(), 60);

    scenario.next_tx(BOB);
    let coin = scenario.take_from_address<Coin<SUI>>(BOB);
    assert_eq!(coin.value(), 40);

    destroy(coin);
    destroy(funds);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_vested_payout_locks_the_amount_in_a_shared_schedule() {
    let mut scenario = test_scenario::begin(ALICE);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    let mut funds = balance::create_for_testing<SUI>(100);
    let terms = payout::vesting_terms(10, 100, 4);
    let recipient = payout::recipient(BOB, option::some(terms));

    let schedule = payout::pay_or_vest(&mut funds, 40, &recipient, &clock, scenario.ctx());
    assert!(schedule.is_some());
    assert_eq!(funds.value(), 60);

    let created = event::events_by_type<VestingCreated>();
    assert_eq!(created.length(), 1);
    let (
        vesting_id,
        _,
        beneficiary,
        refund_recipient,
        cancel_cap_id,
        total,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    ) = created[0].vesting_created_fields();
    assert_eq!(option::some(vesting_id), schedule);
    assert_eq!(beneficiary, BOB);
    assert!(refund_recipient.is_none() && cancel_cap_id.is_none());
    assert_eq!(vector[total, start_ms, cliff_ms, period_ms, periods], vector[40, 1_000, 10, 100, 4]);

    scenario.next_tx(BOB);
    assert!(test_scenario::has_most_recent_shared<Vesting<SUI>>());
    assert!(!test_scenario::has_most_recent_for_address<Coin<SUI>>(BOB));

    destroy(funds);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_zero_payout_sends_and_locks_nothing() {
    let mut scenario = test_scenario::begin(ALICE);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut funds = balance::create_for_testing<SUI>(5);
    let recipient = payout::recipient(BOB, option::some(payout::vesting_terms(0, 1, 1)));

    assert!(payout::pay_or_vest(&mut funds, 0, &recipient, &clock, scenario.ctx()).is_none());
    payout::pay_all(balance::zero<SUI>(), BOB, scenario.ctx());
    assert_eq!(funds.value(), 5);

    scenario.next_tx(BOB);
    assert!(!test_scenario::has_most_recent_for_address<Coin<SUI>>(BOB));

    destroy(funds);
    destroy(clock);
    scenario.end();
}

#[test]
/// The longest schedule is the technical bound, and a payout under it creates the schedule.
fun a_payout_vests_at_the_technical_bound_with_a_full_cliff() {
    let mut scenario = test_scenario::begin(ALICE);
    let clock = clock::create_for_testing(scenario.ctx());
    let max_duration_ms = blast_core::constants::max_vesting_duration_ms!();
    let terms = payout::vesting_terms(max_duration_ms, max_duration_ms, 1);
    // The largest period count is accepted too.
    payout::vesting_terms(0, 1, max_duration_ms);
    let mut funds = balance::create_for_testing<SUI>(1);

    let recipient = payout::recipient(BOB, option::some(terms));
    let schedule = payout::pay_or_vest(&mut funds, 1, &recipient, &clock, scenario.ctx());

    assert!(schedule.is_some());
    assert_eq!(funds.value(), 0);
    destroy(funds);
    destroy(clock);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::payout,
)]
fun vesting_rejects_a_zero_period() {
    payout::vesting_terms(0, 0, 1);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::payout,
)]
fun vesting_rejects_zero_periods() {
    payout::vesting_terms(0, 1, 0);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::payout,
)]
fun vesting_rejects_a_cliff_beyond_the_schedule() {
    payout::vesting_terms(401, 100, 4);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::payout,
)]
fun vesting_rejects_a_schedule_beyond_the_technical_bound() {
    payout::vesting_terms(0, (1 << 62) + 1, 2);
}

#[test]
fun a_recipient_reads_its_vesting_terms() {
    let terms = payout::vesting_terms(10, 100, 4);
    let vested = payout::recipient(BOB, option::some(terms));
    let outright = payout::recipient(BOB, option::none());

    assert_eq!(vested.vesting_terms(), option::some(terms));
    assert!(outright.vesting_terms().is_none());
    assert_eq!(
        vector[terms.cliff_delay_ms(), terms.period_duration_ms(), terms.periods()],
        vector[10, 100, 4],
    );
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidRecipient, location = blast_core::payout)]
fun an_outright_recipient_rejects_the_zero_address() {
    payout::recipient(@0x0, option::none());
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidRecipient, location = blast_core::payout)]
fun a_vested_recipient_rejects_the_zero_address() {
    payout::recipient(@0x0, option::some(payout::vesting_terms(0, 1, 1)));
}

// === Imports ===

use blast_core::payout;

use blast_fun_vesting::blast_fun_linear_vesting::{Vesting, VestingCreated};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, clock, coin::Coin, event, sui::SUI, test_scenario};
