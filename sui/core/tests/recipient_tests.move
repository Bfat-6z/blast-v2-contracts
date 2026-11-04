// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::recipient_tests;

// === Constants ===

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

// === Tests ===

#[test]
fun an_outright_payout_sends_the_exact_amount_and_keeps_the_rest() {
    let mut scenario = test_scenario::begin(ALICE);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut funds = balance::create_for_testing<SUI>(100);

    let schedule = recipient::pay_or_vest(&mut funds, &recipient::new(BOB, bps::new(1)), 40, &clock, scenario.ctx());
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
    let clock = clock::create_for_testing(scenario.ctx());
    let mut funds = balance::create_for_testing<SUI>(100);
    let vested = recipient::vested(BOB, bps::new(1), recipient::vesting_terms(10, 100, 4));

    let schedule = recipient::pay_or_vest(&mut funds, &vested, 40, &clock, scenario.ctx());
    assert!(schedule.is_some());
    assert_eq!(funds.value(), 60);

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
    let vested = recipient::vested(BOB, bps::new(1), recipient::vesting_terms(0, 1, 1));

    assert!(recipient::pay_or_vest(&mut funds, &vested, 0, &clock, scenario.ctx()).is_none());
    recipient::pay_all(balance::zero<SUI>(), BOB, scenario.ctx());
    assert_eq!(funds.value(), 5);

    scenario.next_tx(BOB);
    assert!(!test_scenario::has_most_recent_for_address<Coin<SUI>>(BOB));

    destroy(funds);
    destroy(clock);
    scenario.end();
}

#[test]
fun vesting_accepts_the_technical_bound_with_a_full_cliff() {
    let max_duration_ms = 1 << 63;
    let terms = recipient::vesting_terms(max_duration_ms, max_duration_ms, 1);
    assert_eq!(terms.periods(), 1);
    recipient::vesting_terms(0, 1, max_duration_ms);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::recipient,
)]
fun vesting_rejects_a_cliff_beyond_the_schedule() {
    recipient::vesting_terms(401, 100, 4);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidVestingTerms,
    location = blast_core::recipient,
)]
fun vesting_rejects_a_schedule_beyond_the_technical_bound() {
    recipient::vesting_terms(0, (1 << 62) + 1, 2);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidRecipient,
    location = blast_core::recipient,
)]
fun a_recipient_must_be_a_nonzero_address() {
    recipient::new(@0x0, bps::new(1));
}

#[test]
fun a_valid_list_passes_with_and_without_vesting() {
    let list = vector[recipient::new(ALICE, bps::new(1)), recipient::new(BOB, bps::new(2))];
    recipient::assert_valid(&list, 2, false);
    let vested = vector[recipient::vested(ALICE, bps::new(1), recipient::vesting_terms(0, 1, 1))];
    recipient::assert_valid(&vested, 1, true);
    assert_eq!(recipient::rates(&list), vector[bps::new(1), bps::new(2)]);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidRecipients,
    location = blast_core::recipient,
)]
fun a_list_rejects_a_repeated_address() {
    let list = vector[recipient::new(ALICE, bps::new(1)), recipient::new(ALICE, bps::new(2))];
    recipient::assert_valid(&list, 2, false);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidRecipients,
    location = blast_core::recipient,
)]
fun a_list_rejects_vesting_where_it_is_not_allowed() {
    let vested = vector[recipient::vested(ALICE, bps::new(1), recipient::vesting_terms(0, 1, 1))];
    recipient::assert_valid(&vested, 1, false);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidRecipients,
    location = blast_core::recipient,
)]
fun a_list_rejects_a_zero_share_and_the_first_over_capacity() {
    recipient::assert_valid(&vector[recipient::new(ALICE, bps::new(0))], 1, false);
}

// === Imports ===

use blast_core::{bps, recipient};

use blast_fun_vesting::blast_fun_linear_vesting::Vesting;

use std::unit_test::{assert_eq, destroy};

use sui::{balance, clock, coin::Coin, sui::SUI, test_scenario};
