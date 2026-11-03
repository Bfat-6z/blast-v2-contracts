// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_tests;

// === Constants ===

const NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct Fee() has copy, drop, store;

public struct Upgrade() has copy, drop, store;

public struct Witnesses() has copy, drop, store;

// === Tests ===

// --- Delayed ---

#[test]
fun creation_records_owner_key_value_and_notice() {
    let setting = new_setting(7, NOTICE_MS);

    let created = collect<DelayedCreated<Fee, u64>>();
    let (owner, key, value, delay_ms) = created.delayed_created_fields();
    assert_eq!(owner, owner());
    assert_eq!(key, Fee());
    assert_eq!(value, 7);
    assert_eq!(delay_ms, NOTICE_MS);

    setting.destroy();
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
    setting.destroy();
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

    setting.destroy();
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
    setting.destroy();
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
    setting.destroy();
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

    setting.destroy();
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

    setting.destroy();
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
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed)]
fun a_setting_with_a_proposal_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut setting = new_setting(0, NOTICE_MS);
    setting.schedule_value(1, &clock);

    setting.destroy();

    abort
}

#[test]
fun the_largest_representable_deadline_is_valid() {
    let mut clock = clock_at(10);
    let mut setting = new_setting(7, std::u64::max_value!() - 10);

    assert_eq!(setting.schedule(2, 0, &clock), std::u64::max_value!());
    clock.set_for_testing(std::u64::max_value!());
    assert_eq!(setting.apply(&clock), 2);

    setting.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_overflowing_deadline() {
    let clock = clock_at(1);
    let mut setting = new_setting(7, std::u64::max_value!());

    setting.schedule_value(8, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_notice_must_fit_at_its_earliest_application() {
    let clock = clock_at(1);
    let mut setting = new_setting(7, 1);

    setting.schedule_delay(std::u64::max_value!() - 1, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun applying_late_rejects_a_now_unrepresentable_notice() {
    let mut clock = clock_at(1);
    let mut setting = new_setting(7, 1);
    setting.schedule_delay(std::u64::max_value!() - 2, &clock);

    clock.set_for_testing(3);
    setting.apply(&clock);

    abort
}

// --- DelayedAction ---

#[test]
fun an_action_waits_the_applied_notice_and_is_handed_back_once() {
    let mut clock = clock_at(5);
    let mut slot = new_slot(NOTICE_MS);
    let (_, _, created_delay_ms) = collect<ActionCreated<Upgrade, u64>>().action_created_fields();
    assert_eq!(created_delay_ms, NOTICE_MS);

    assert_eq!(slot.schedule(42, &clock), 5 + NOTICE_MS);
    let scheduled = collect<ActionScheduled<Upgrade, u64>>();
    let (owner, _, change, delay_ms, ready_at_ms) = scheduled.action_scheduled_fields();
    assert_eq!(owner, owner());
    assert_eq!(change.action(), option::some(42));
    assert_eq!(delay_ms, NOTICE_MS);
    assert_eq!(ready_at_ms, 5 + NOTICE_MS);

    clock.set_for_testing(5 + NOTICE_MS);
    assert_eq!(slot.take_action(&clock), 42);
    let (_, _, applied_change, _) = collect<ActionApplied<Upgrade, u64>>().action_applied_fields();
    assert_eq!(applied_change.action(), option::some(42));
    assert_eq!(slot.delay_ms(), NOTICE_MS);
    assert!(slot.pending().is_none());

    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_notice_change_waits_the_applied_notice_and_replaces_a_pending_action() {
    let mut clock = clock_at(0);
    let mut slot = new_slot(100);
    slot.schedule(42, &clock);
    clock.set_for_testing(10);

    assert_eq!(slot.schedule_delay(0, &clock), 110);

    let cancelled = collect<ActionCancelled<Upgrade, u64>>();
    let (_, _, cancelled_change, _, _) = cancelled.action_cancelled_fields();
    assert_eq!(cancelled_change.action(), option::some(42));
    let pending = slot.pending().destroy_some();
    assert!(pending.value().action().is_none());
    assert_eq!(pending.delay_ms(), 0);

    clock.set_for_testing(110);
    slot.apply_delay(&clock);
    assert_eq!(slot.delay_ms(), 0);
    assert_eq!(slot.schedule(7, &clock), 110);
    assert_eq!(slot.take_action(&clock), 7);

    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed)]
fun a_notice_change_cannot_be_taken_as_an_action() {
    let clock = clock_at(0);
    let mut slot = new_slot(0);
    slot.schedule_delay(10, &clock);

    slot.take_action(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed)]
fun an_action_cannot_be_applied_as_a_notice_change() {
    let clock = clock_at(0);
    let mut slot = new_slot(0);
    slot.schedule(1, &clock);

    slot.apply_delay(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun proposing_the_applied_notice_rejects() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);

    slot.schedule_delay(10, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun an_action_cannot_be_taken_early() {
    let mut clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule(1, &clock);

    clock.set_for_testing(9);
    slot.take_action(&clock);

    abort
}

#[test]
fun a_ready_action_can_still_be_cancelled() {
    let mut clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule(1, &clock);
    clock.set_for_testing(10);

    slot.cancel();

    assert!(slot.pending().is_none());
    assert_eq!(slot.delay_ms(), 10);

    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed)]
fun a_slot_with_a_proposal_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule(1, &clock);

    slot.destroy();

    abort
}

// --- DelayedSet ---

#[test]
fun an_admission_waits_the_applied_notice_and_removal_is_immediate() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(NOTICE_MS);

    assert_eq!(set.schedule_add(@0xA, &clock), NOTICE_MS);
    assert!(!set.contains(&@0xA));
    assert_eq!(set.admission_ready_at_ms(&@0xA), option::some(NOTICE_MS));

    clock.set_for_testing(NOTICE_MS);
    set.apply_add(@0xA, &clock);
    assert!(set.contains(&@0xA));
    assert!(set.admission_ready_at_ms(&@0xA).is_none());
    let applied = collect<ActionApplied<Witnesses, address>>();
    let (_, _, applied_change, _) = applied.action_applied_fields();
    assert_eq!(applied_change.action(), option::some(@0xA));

    set.remove(@0xA);
    assert!(!set.contains(&@0xA));
    let (owner, _, member) = collect<MemberRemoved<Witnesses, address>>().member_removed_fields();
    assert_eq!(owner, owner());
    assert_eq!(member, @0xA);
    assert_eq!(set.delay_ms(), NOTICE_MS);

    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun zero_notice_admissions_apply_in_one_transaction_before_the_notice_is_raised() {
    let clock = clock_at(3);
    let mut set = new_witness_set(0);

    set.schedule_add(@0xA, &clock);
    set.apply_add(@0xA, &clock);
    set.schedule_add(@0xB, &clock);
    set.apply_add(@0xB, &clock);
    set.schedule_delay(NOTICE_MS, &clock);
    set.apply_delay(&clock);

    assert!(set.contains(&@0xA) && set.contains(&@0xB));
    assert_eq!(set.members().length(), 2);
    assert_eq!(set.delay_ms(), NOTICE_MS);
    assert_eq!(set.schedule_add(@0xC, &clock), 3 + NOTICE_MS);

    set.cancel_add(@0xC);
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun admissions_keep_their_deadlines_across_notice_changes() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(100);
    set.schedule_add(@0xA, &clock);

    assert_eq!(set.schedule_delay(1_000, &clock), 100);
    assert_eq!(set.schedule_add(@0xB, &clock), 100);
    clock.set_for_testing(100);
    set.apply_delay(&clock);
    assert_eq!(set.pending_delay().is_none(), true);

    assert_eq!(set.admission_ready_at_ms(&@0xA), option::some(100));
    set.apply_add(@0xA, &clock);
    set.apply_add(@0xB, &clock);
    assert_eq!(set.schedule_add(@0xC, &clock), 1_100);

    set.cancel_add(@0xC);
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun removal_discards_a_pending_admission_without_changing_the_notice() {
    let clock = clock_at(0);
    let mut set = new_witness_set(100);
    set.schedule_add(@0xA, &clock);

    set.remove(@0xA);

    let cancelled = collect<ActionCancelled<Witnesses, address>>();
    let (_, _, cancelled_change, _, _) = cancelled.action_cancelled_fields();
    assert_eq!(cancelled_change.action(), option::some(@0xA));
    assert!(set.admission_ready_at_ms(&@0xA).is_none());
    assert_eq!(set.delay_ms(), 100);

    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun rescheduling_a_pending_member_restarts_its_notice() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(100);
    set.schedule_add(@0xA, &clock);
    clock.set_for_testing(40);

    assert_eq!(set.schedule_add(@0xA, &clock), 140);
    let (_, _, _, _, cancelled_ready_at_ms) = collect<ActionCancelled<Witnesses, address>>()
        .action_cancelled_fields();
    assert_eq!(cancelled_ready_at_ms, 100);

    set.cancel_add(@0xA);
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun an_admitted_member_cannot_be_scheduled_again() {
    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    set.schedule_add(@0xA, &clock);
    set.apply_add(@0xA, &clock);

    set.schedule_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun removing_an_unknown_member_rejects() {
    let mut set = new_witness_set(0);

    set.remove(@0xA);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun an_admission_cannot_apply_early() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_add(@0xA, &clock);

    clock.set_for_testing(9);
    set.apply_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun applying_an_unscheduled_admission_rejects() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);

    set.apply_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed)]
fun a_set_with_a_pending_admission_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_add(@0xA, &clock);

    set.destroy();

    abort
}

#[test]
fun destruction_records_the_end_of_each_value() {
    let setting = new_setting(7, 0);
    setting.destroy();
    let (setting_owner, _) = collect<DelayedDestroyed<Fee, u64>>().delayed_destroyed_fields();
    assert_eq!(setting_owner, owner());

    let slot = new_slot(0);
    slot.destroy();
    let (slot_owner, _) = collect<ActionDestroyed<Upgrade, u64>>().action_destroyed_fields();
    assert_eq!(slot_owner, owner());

    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    set.schedule_add(@0xA, &clock);
    set.apply_add(@0xA, &clock);
    set.destroy();
    let (set_owner, _) = collect<ActionDestroyed<Witnesses, address>>().action_destroyed_fields();
    assert_eq!(set_owner, owner());

    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed)]
fun the_change_kind_is_checked_before_readiness() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule_delay(20, &clock);

    slot.take_action(&clock);

    abort
}

#[test]
fun an_applied_notice_change_records_the_new_notice() {
    let mut clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule_delay(20, &clock);
    clock.set_for_testing(10);

    slot.apply_delay(&clock);

    let (_, _, change, delay_ms) = collect<ActionApplied<Upgrade, u64>>().action_applied_fields();
    assert!(change.action().is_none());
    assert_eq!(delay_ms, 20);
    assert_eq!(slot.delay_ms(), 20);

    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_replaced_notice_change_is_cancelled_first() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_delay(20, &clock);

    set.schedule_delay(30, &clock);

    let (_, _, change, delay_ms, _) = collect<ActionCancelled<Witnesses, address>>()
        .action_cancelled_fields();
    assert!(change.action().is_none());
    assert_eq!(delay_ms, 20);
    assert_eq!(set.pending_delay().destroy_some().delay_ms(), 30);

    set.cancel_delay();
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_cancelled_admission_reports_the_notice_it_was_scheduled_with() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_add(@0xA, &clock);
    set.schedule_delay(500, &clock);
    clock.set_for_testing(10);
    set.apply_delay(&clock);

    set.cancel_add(@0xA);

    let (_, _, _, delay_ms, ready_at_ms) = collect<ActionCancelled<Witnesses, address>>()
        .action_cancelled_fields();
    assert_eq!(delay_ms, 10);
    assert_eq!(ready_at_ms, 10);

    set.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun cancelling_an_unscheduled_admission_rejects() {
    let mut set = new_witness_set(10);

    set.cancel_add(@0xA);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed)]
fun cancelling_a_missing_notice_change_rejects() {
    let mut set = new_witness_set(10);

    set.cancel_delay();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed)]
fun a_set_with_a_pending_notice_change_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_delay(20, &clock);

    set.destroy();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed)]
fun an_unchanged_proposal_rejects_before_overflow_checks() {
    let clock = clock_at(1);
    let mut setting = new_setting(7, std::u64::max_value!());

    setting.schedule(7, std::u64::max_value!(), &clock);

    abort
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

fun new_slot(delay_ms: u64): DelayedAction<Upgrade, u64> {
    let uid = owner_uid();
    let slot = delayed::new_action(Upgrade(), &uid, delay_ms);
    uid.delete();
    slot
}

fun new_witness_set(delay_ms: u64): DelayedSet<Witnesses, address> {
    let uid = owner_uid();
    let set = delayed::new_set(Witnesses(), &uid, delay_ms);
    uid.delete();
    set
}

fun collect<Event: copy + drop>(): Event {
    let mut events = sui::event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{
    delayed::{
        Self,
        ActionApplied,
        ActionCancelled,
        ActionCreated,
        ActionDestroyed,
        ActionScheduled,
        Delayed,
        DelayedAction,
        DelayedApplied,
        DelayedCancelled,
        DelayedCreated,
        DelayedDestroyed,
        DelayedScheduled,
        DelayedSet,
        MemberRemoved,
    },
    errors,
};

use std::unit_test::assert_eq;

use sui::clock::{Self, Clock};
