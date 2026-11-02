// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_tests;

// === Tests ===

#[test]
fun reads_stay_applied_until_an_explicit_apply_at_the_boundary() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(7u64);
    assert_eq!(setting.schedule(9, 172_800_000, &clock), 172_800_010);
    assert_eq!(setting.value(), 7);
    clock.set_for_testing(172_800_010);
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.apply(&clock), 9);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun one_millisecond_before_ready_is_rejected() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_799_999);
    setting.apply(&clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun replacing_a_ready_proposal_restarts_the_entire_delay() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_800_000);
    setting.schedule(2, 172_800_000, &clock);
    setting.apply(&clock);
    abort
}

#[test]
fun cancellation_after_readiness_preserves_the_applied_value() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(3u64);
    setting.schedule(5, 172_800_000, &clock);
    clock.set_for_testing(172_800_001);
    assert_eq!(setting.cancel(), 5);
    assert_eq!(setting.value(), 3);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::ENoPending, location = blast_admin::delayed)]
fun an_applied_proposal_cannot_be_replayed() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_800_000);
    setting.apply(&clock);
    setting.apply(&clock);
    abort
}

#[test]
fun immediate_revocation_discards_a_pending_replacement() {
    let clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(vector[1u8]);
    setting.schedule(vector[2u8], 172_800_000, &clock);
    setting.set_now(vector[]);
    assert!(setting.value().is_empty());
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun caller_selected_delays_and_zero_use_exact_thresholds() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(1u64);
    assert_eq!(setting.schedule(2, 25, &clock), 35);
    assert_eq!(setting.pending().destroy_some().ready_at_ms(), 35);
    clock.set_for_testing(35);
    assert_eq!(setting.apply(&clock), 2);
    assert_eq!(setting.schedule(3, 0, &clock), 35);
    assert_eq!(setting.apply(&clock), 3);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun delay_changes_use_old_policy_and_existing_deadlines_are_immutable() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut policy = delayed::new(0u64);
    let mut setting = delayed::new(1u64);
    setting.schedule(2, policy.value(), &clock);
    policy.schedule_delay(100, &clock);
    policy.apply_delay(&clock);
    assert_eq!(setting.pending().destroy_some().ready_at_ms(), 0);
    setting.apply(&clock);
    setting.schedule(3, policy.value(), &clock);
    assert_eq!(setting.pending().destroy_some().ready_at_ms(), 100);
    policy.schedule_delay(25, &clock);
    clock.set_for_testing(100);
    policy.apply_delay(&clock);
    assert_eq!(setting.pending().destroy_some().ready_at_ms(), 100);
    setting.apply(&clock);
    assert_eq!(setting.schedule(4, policy.value(), &clock), 125);
    policy.destroy_for_testing();
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun reducing_the_delay_to_zero_still_waits_the_old_notice() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut policy = delayed::new(100u64);
    policy.schedule_delay(0, &clock);
    clock.set_for_testing(99);
    policy.apply_delay(&clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::EDelayUnchanged, location = blast_admin::delayed)]
fun rescheduling_the_applied_delay_is_rejected() {
    let clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut policy = delayed::new(100u64);
    policy.schedule_delay(100, &clock);
    abort
}

#[test]
fun the_largest_representable_deadline_is_valid() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(1u64);
    assert_eq!(setting.schedule(2, std::u64::max_value!() - 10, &clock), std::u64::max_value!());
    clock.set_for_testing(std::u64::max_value!());
    assert_eq!(setting.apply(&clock), 2);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_overflowing_deadline() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    delayed::new_pending(1u64, std::u64::max_value!(), &clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_delay_must_fit_at_its_earliest_application() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    let mut policy = delayed::new(1u64);
    policy.schedule_delay(std::u64::max_value!() - 1, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::EInvalidDelay, location = blast_admin::delayed)]
fun applying_a_delay_too_late_rejects_a_now_unrepresentable_notice() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    let mut policy = delayed::new(1u64);
    policy.schedule_delay(std::u64::max_value!() - 2, &clock);
    clock.set_for_testing(3);
    policy.apply_delay(&clock);
    abort
}

// === Imports ===

use blast_admin::delayed;
use std::unit_test::assert_eq;
use sui::clock;
