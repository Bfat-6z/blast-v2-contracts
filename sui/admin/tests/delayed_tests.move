// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_tests;

// === Tests ===

#[test]
fun reads_stay_applied_until_an_explicit_apply_at_the_boundary() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(7u64, 172_800_000);
    assert_eq!(setting.schedule(9, 172_800_000, &clock), 172_800_010);
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.pending().destroy_some().value(), 9);
    clock.set_for_testing(172_800_010);
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.apply(&clock), 9);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun one_millisecond_before_ready_is_rejected() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64, 172_800_000);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_799_999);
    setting.apply(&clock);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun replacing_a_ready_proposal_restarts_the_entire_delay() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64, 172_800_000);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_800_000);
    setting.schedule(2, 172_800_000, &clock);
    setting.apply(&clock);
    abort
}

#[test]
fun cancellation_after_readiness_preserves_the_applied_value() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(3u64, 172_800_000);
    setting.schedule(5, 172_800_000, &clock);
    clock.set_for_testing(172_800_001);
    assert_eq!(setting.cancel(), 5);
    assert_eq!(setting.value(), 3);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun an_applied_proposal_cannot_be_replayed() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64, 172_800_000);
    setting.schedule(1, 172_800_000, &clock);
    clock.set_for_testing(172_800_000);
    setting.apply(&clock);
    setting.apply(&clock);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun reducing_the_delay_to_zero_still_waits_the_old_notice() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut policy = delayed::new(7u64, 100);
    policy.schedule_delay(0, &clock);
    clock.set_for_testing(99);
    policy.apply(&clock);
    abort
}

#[test]
fun the_largest_representable_deadline_is_valid() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(7u64, std::u64::max_value!() - 10);
    assert_eq!(setting.schedule(2, 0, &clock), std::u64::max_value!());
    clock.set_for_testing(std::u64::max_value!());
    assert_eq!(setting.apply(&clock), 2);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_overflowing_deadline() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    delayed::new_pending(1u64, std::u64::max_value!(), 0, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_delay_must_fit_at_its_earliest_application() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    let mut policy = delayed::new(7u64, 1);
    policy.schedule_delay(std::u64::max_value!() - 1, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun applying_a_delay_too_late_rejects_a_now_unrepresentable_notice() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(1);
    let mut policy = delayed::new(7u64, 1);
    policy.schedule_delay(std::u64::max_value!() - 2, &clock);
    clock.set_for_testing(3);
    policy.apply(&clock);
    abort
}


#[test]
fun value_and_notice_apply_atomically_and_shortening_does_not_change_this_deadline() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(1u64, 100);
    assert_eq!(setting.schedule(2, 25, &clock), 110);
    let pending = setting.pending().destroy_some();
    assert_eq!(pending.value(), 2);
    assert_eq!(pending.delay_ms(), 25);
    assert_eq!(setting.value(), 1);
    assert_eq!(setting.delay_ms(), 100);
    clock.set_for_testing(110);
    assert_eq!(setting.apply(&clock), 2);
    assert_eq!(setting.delay_ms(), 25);
    assert_eq!(setting.schedule_value(3, &clock), 135);
    clock.set_for_testing(135);
    setting.apply(&clock);
    assert_eq!(setting.delay_ms(), 25);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun delay_only_replaces_pending_value_with_applied_value_and_cancel_preserves_both() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(7u64, 100);
    setting.schedule(9, 200, &clock);
    clock.set_for_testing(50);
    assert_eq!(setting.schedule_delay(25, &clock), 150);
    assert_eq!(setting.pending().destroy_some().value(), 7);
    clock.set_for_testing(150);
    setting.cancel();
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.delay_ms(), 100);
    setting.schedule_delay(25, &clock);
    clock.set_for_testing(250);
    assert_eq!(setting.apply(&clock), 7);
    assert_eq!(setting.delay_ms(), 25);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun zero_notice_bootstrap_can_enable_delay_but_disabling_it_waits_current_notice() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(7u64, 0);
    assert_eq!(setting.schedule(8, 100, &clock), 0);
    setting.apply(&clock);
    assert_eq!(setting.schedule(9, 0, &clock), 100);
    assert_eq!(setting.value(), 8);
    assert_eq!(setting.delay_ms(), 100);
    clock.set_for_testing(100);
    setting.apply(&clock);
    assert_eq!(setting.delay_ms(), 0);
    assert_eq!(setting.schedule_value(10, &clock), 100);
    setting.apply(&clock);
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun future_scheduling_still_checks_overflow_after_a_valid_application() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(7u64, 0);
    setting.schedule_delay(100, &clock);
    setting.apply(&clock);
    clock.set_for_testing(std::u64::max_value!() - 99);
    setting.schedule_value(8, &clock);
    abort
}

// === Imports ===

use blast_admin::delayed;
use std::unit_test::assert_eq;
use sui::clock;
