// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_tests;

// === Constants ===

const NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct Fee() has copy, drop, store;

// === Tests ===

#[test]
fun creation_records_owner_key_value_and_notice() {
    let setting = new_setting(7, NOTICE_MS);

    let created = collect<DelayedCreated<Fee, u64>>();
    let (owner, key, value, delay_ms) = created.delayed_created_fields();
    assert_eq!(owner, owner());
    assert_eq!(key, Fee());
    assert_eq!(value, 7);
    assert_eq!(delay_ms, NOTICE_MS);

    destroy(setting);
}

#[test]
fun zero_notice_schedules_and_applies_in_one_transaction() {
    let clock = clock_at(10);
    let mut setting = new_setting(7, 0);

    assert_eq!(setting.schedule_value(8, &clock), 10);
    assert_eq!(setting.apply(&clock), 8);
    assert_eq!(setting.schedule_delay(NOTICE_MS, &clock), 10);
    setting.apply(&clock);

    assert_eq!(setting.value(), 8);
    assert_eq!(setting.delay_ms(), NOTICE_MS);
    assert_eq!(setting.schedule_value(9, &clock), 10 + NOTICE_MS);

    setting.cancel();
    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
fun reads_stay_applied_until_an_explicit_apply_at_the_boundary() {
    let mut clock = clock_at(10);
    let mut setting = new_setting(7, NOTICE_MS);

    assert_eq!(setting.schedule_value(9, &clock), NOTICE_MS + 10);
    clock.set_for_testing(NOTICE_MS + 10);
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.pending().destroy_some().value(), 9);

    assert_eq!(setting.apply(&clock), 9);
    let applied = collect<DelayedApplied<Fee, u64>>();
    let (owner, key, previous_value, value, delay_ms) = applied.delayed_applied_fields();
    assert_eq!(owner, owner());
    assert_eq!(key, Fee());
    assert_eq!(previous_value, 7);
    assert_eq!(value, 9);
    assert_eq!(delay_ms, NOTICE_MS);
    assert!(setting.pending().is_none());

    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
fun value_and_notice_apply_together_and_a_shorter_notice_waits_the_applied_one() {
    let mut clock = clock_at(10);
    let mut setting = new_setting(1, 100);

    assert_eq!(setting.schedule(2, 25, &clock), 110);
    let scheduled = collect<DelayedScheduled<Fee, u64>>();
    let (_, _, value, delay_ms, ready_at_ms) = scheduled.delayed_scheduled_fields();
    assert_eq!(value, 2);
    assert_eq!(delay_ms, 25);
    assert_eq!(ready_at_ms, 110);
    assert_eq!(setting.delay_ms(), 100);

    clock.set_for_testing(110);
    setting.apply(&clock);
    assert_eq!(setting.delay_ms(), 25);
    assert_eq!(setting.schedule_value(3, &clock), 135);

    setting.cancel();
    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun reducing_the_notice_to_zero_still_waits_the_applied_notice() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(7, 100);
    setting.schedule_delay(0, &clock);

    clock.set_for_testing(99);
    setting.apply(&clock);

    abort
}

#[test]
fun replacement_cancels_the_previous_proposal_and_restarts_the_notice() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(0, NOTICE_MS);
    setting.schedule_value(1, &clock);
    clock.set_for_testing(NOTICE_MS);

    assert_eq!(setting.schedule_value(2, &clock), 2 * NOTICE_MS);

    let cancelled = collect<DelayedCancelled<Fee, u64>>();
    let (_, _, value, _, ready_at_ms) = cancelled.delayed_cancelled_fields();
    assert_eq!(value, 1);
    assert_eq!(ready_at_ms, NOTICE_MS);
    assert_eq!(setting.pending().destroy_some().value(), 2);

    setting.cancel();
    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
fun cancellation_after_readiness_preserves_the_applied_value_and_notice() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(3, NOTICE_MS);
    setting.schedule(5, 1, &clock);
    clock.set_for_testing(NOTICE_MS + 1);

    setting.cancel();

    let (_, _, cancelled_value, _, _) = collect<DelayedCancelled<Fee, u64>>().delayed_cancelled_fields();
    assert_eq!(cancelled_value, 5);
    assert_eq!(setting.value(), 3);
    assert_eq!(setting.delay_ms(), NOTICE_MS);
    assert!(setting.pending().is_none());

    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun a_cancelled_proposal_cannot_be_cancelled_again() {
    let clock = clock_at(0);
    let mut setting = new_setting(3, NOTICE_MS);
    setting.schedule_value(5, &clock);
    setting.cancel();
    assert!(setting.pending().is_none());

    setting.cancel();

    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
fun readiness_validation_is_repeatable_and_changes_nothing() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(7, 10);
    setting.schedule(9, 25, &clock);
    clock.set_for_testing(10);

    setting.assert_ready(&clock);
    setting.assert_ready(&clock);

    assert_eq!(setting.value(), 7);
    assert_eq!(setting.delay_ms(), 10);
    assert_eq!(setting.apply(&clock), 9);

    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun scheduling_the_applied_value_and_notice_rejects() {
    let clock = clock_at(0);
    let mut setting = new_setting(7, 10);

    setting.schedule(7, 10, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun readiness_without_a_proposal_rejects() {
    let clock = clock_at(0);
    let setting = new_setting(7, 10);

    setting.assert_ready(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun an_applied_proposal_cannot_be_replayed() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(0, NOTICE_MS);
    setting.schedule_value(1, &clock);
    clock.set_for_testing(NOTICE_MS);
    setting.apply(&clock);

    setting.apply(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun cancellation_without_a_proposal_rejects() {
    let mut setting = new_setting(0, NOTICE_MS);

    setting.cancel();

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun one_millisecond_before_ready_rejects() {
    let mut clock = clock_at(0);
    let mut setting = new_setting(0, NOTICE_MS);
    setting.schedule_value(1, &clock);

    clock.set_for_testing(NOTICE_MS - 1);
    setting.apply(&clock);

    abort
}

#[test]
fun the_largest_representable_deadline_is_valid() {
    let max = std::u64::max_value!();
    let mut clock = clock_at(max - delayed::max_delay_ms());
    let mut setting = new_setting(7, delayed::max_delay_ms());

    assert_eq!(setting.schedule(2, 0, &clock), max);
    clock.set_for_testing(max);
    assert_eq!(setting.apply(&clock), 2);

    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
fun the_ceiling_notice_is_accepted_and_can_be_changed_again() {
    let mut clock = clock_at(1);
    let mut setting = new_setting(7, NOTICE_MS);
    setting.schedule_delay(delayed::max_delay_ms(), &clock);
    clock.set_for_testing(1 + NOTICE_MS);
    setting.apply(&clock);
    assert_eq!(setting.delay_ms(), delayed::max_delay_ms());

    let ready_at_ms = setting.schedule_delay(NOTICE_MS, &clock);
    clock.set_for_testing(ready_at_ms);
    setting.apply(&clock);

    assert_eq!(setting.delay_ms(), NOTICE_MS);
    destroy(setting);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun creation_rejects_a_notice_above_the_ceiling() {
    let setting = new_setting(7, delayed::max_delay_ms() + 1);

    destroy(setting);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_notice_above_the_ceiling_rejects() {
    let clock = clock_at(1);
    let mut setting = new_setting(7, NOTICE_MS);

    setting.schedule_delay(delayed::max_delay_ms() + 1, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_overflowing_deadline() {
    let clock = clock_at(std::u64::max_value!() - 1);
    let mut setting = new_setting(7, 2);

    setting.schedule_value(8, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_notice_must_fit_at_its_earliest_application() {
    let clock = clock_at(std::u64::max_value!() - delayed::max_delay_ms());
    let mut setting = new_setting(7, 1);

    setting.schedule_delay(delayed::max_delay_ms(), &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun applying_late_rejects_a_now_unrepresentable_notice() {
    let start_ms = std::u64::max_value!() - delayed::max_delay_ms() - 2;
    let mut clock = clock_at(start_ms);
    let mut setting = new_setting(7, 1);
    setting.schedule_delay(delayed::max_delay_ms(), &clock);

    clock.set_for_testing(start_ms + 3);
    setting.apply(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun an_unchanged_proposal_rejects_before_ceiling_and_overflow_checks() {
    let clock = clock_at(std::u64::max_value!());
    let mut setting = new_setting(7, delayed::max_delay_ms());

    setting.schedule(7, delayed::max_delay_ms(), &clock);

    abort
}

#[test]
fun a_setting_is_guarded_only_with_a_nonzero_notice_and_no_zero_notice_proposal() {
    let clock = clock_at(0);
    let mut setting = new_setting(7, 0);
    assert!(!setting.is_guarded());

    setting.schedule_delay(NOTICE_MS, &clock);
    setting.apply(&clock);
    assert!(setting.is_guarded());

    setting.schedule_value(8, &clock);
    assert!(setting.is_guarded());

    setting.schedule(8, 0, &clock);
    assert!(!setting.is_guarded());

    setting.cancel();
    assert!(setting.is_guarded());

    destroy(setting);
    clock.destroy_for_testing();
}

// === Test Helpers ===

/// A dummy context derives the same first object ID every time.
fun owner_uid(): UID {
    object::new(&mut tx_context::dummy())
}

fun owner(): ID {
    let uid = owner_uid();
    let owner = uid.to_inner();
    uid.delete();
    owner
}

fun clock_at(timestamp_ms: u64): Clock {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(timestamp_ms);
    clock
}

fun new_setting(value: u64, delay_ms: u64): Delayed<Fee, u64> {
    let uid = owner_uid();
    let setting = delayed::new(Fee(), &uid, value, delay_ms);
    uid.delete();
    setting
}

fun collect<Event: copy + drop>(): Event {
    let mut events = sui::event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{
    delayed::{
        Self,
        Delayed,
        DelayedApplied,
        DelayedCancelled,
        DelayedCreated,
        DelayedScheduled,
    },
    errors,
};

use std::unit_test::{assert_eq, destroy};

use sui::clock::{Self, Clock};
