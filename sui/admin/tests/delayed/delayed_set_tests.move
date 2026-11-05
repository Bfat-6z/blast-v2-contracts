// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_set_tests;

// === Constants ===

const NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct Witnesses() has copy, drop, store;

// === Tests ===

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
    let applied = collect<SetApplied<Witnesses, address>>();
    let (_, _, applied_change, _) = applied.set_applied_fields();
    assert_eq!(applied_change.member_for_testing(), option::some(@0xA));

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
    assert_eq!(set.pending_delay_ms_for_testing().is_none(), true);

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

    let cancelled = collect<SetCancelled<Witnesses, address>>();
    let (_, _, cancelled_change, _, _) = cancelled.set_cancelled_fields();
    assert_eq!(cancelled_change.member_for_testing(), option::some(@0xA));
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
    let (_, _, _, _, cancelled_ready_at_ms) = collect<SetCancelled<Witnesses, address>>()
        .set_cancelled_fields();
    assert_eq!(cancelled_ready_at_ms, 100);

    set.cancel_add(@0xA);
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
/// Counts pending admissions only: a reschedule replaces one, and applying, cancelling or
/// removing a member drops it, while admitted members and notice changes never count.
fun pending_count_counts_only_pending_admissions() {
    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    assert_eq!(set.pending_count(), 0);

    set.schedule_add(@0xA, &clock);
    set.schedule_add(@0xB, &clock);
    set.schedule_add(@0xC, &clock);
    set.schedule_add(@0xA, &clock);
    assert_eq!(set.pending_count(), 3);

    set.apply_add(@0xA, &clock);
    set.schedule_delay(100, &clock);
    assert_eq!(set.pending_count(), 2);
    assert_eq!(set.members().length(), 1);

    set.cancel_add(@0xB);
    set.remove(@0xC);
    assert_eq!(set.pending_count(), 0);

    set.cancel_delay();
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_set)]
fun an_admitted_member_cannot_be_scheduled_again() {
    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    set.schedule_add(@0xA, &clock);
    set.apply_add(@0xA, &clock);

    set.schedule_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_set)]
fun removing_an_unknown_member_rejects() {
    let mut set = new_witness_set(0);

    set.remove(@0xA);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed_set)]
fun an_admission_cannot_apply_early() {
    let mut clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_add(@0xA, &clock);

    clock.set_for_testing(9);
    set.apply_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_set)]
fun applying_an_unscheduled_admission_rejects() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);

    set.apply_add(@0xA, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed_set)]
fun a_set_with_a_pending_admission_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_add(@0xA, &clock);

    set.destroy();

    abort
}

#[test]
fun a_replaced_notice_change_is_cancelled_first() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_delay(20, &clock);

    set.schedule_delay(30, &clock);

    let (_, _, change, delay_ms, _) = collect<SetCancelled<Witnesses, address>>()
        .set_cancelled_fields();
    assert!(change.member_for_testing().is_none());
    assert_eq!(delay_ms, 20);
    assert_eq!(set.pending_delay_ms_for_testing().destroy_some(), 30);

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

    let (_, _, _, delay_ms, ready_at_ms) = collect<SetCancelled<Witnesses, address>>()
        .set_cancelled_fields();
    assert_eq!(delay_ms, 10);
    assert_eq!(ready_at_ms, 10);

    set.destroy();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_set)]
fun cancelling_an_unscheduled_admission_rejects() {
    let mut set = new_witness_set(10);

    set.cancel_add(@0xA);

    abort
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_set)]
fun cancelling_a_missing_notice_change_rejects() {
    let mut set = new_witness_set(10);

    set.cancel_delay();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed_set)]
fun a_set_with_a_pending_notice_change_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);
    set.schedule_delay(20, &clock);

    set.destroy();

    abort
}

#[test]
fun destruction_records_the_end_of_the_set_and_its_members() {
    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    set.schedule_add(@0xA, &clock);
    set.apply_add(@0xA, &clock);

    set.destroy();

    let (set_owner, _) = collect<SetDestroyed<Witnesses, address>>().set_destroyed_fields();
    assert_eq!(set_owner, owner());

    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun creation_rejects_a_notice_above_the_ceiling() {
    let set = new_witness_set(delayed::max_delay_ms() + 1);

    set.destroy();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_notice_above_the_ceiling_rejects() {
    let clock = clock_at(0);
    let mut set = new_witness_set(10);

    set.schedule_delay(delayed::max_delay_ms() + 1, &clock);

    abort
}

#[test]
fun a_set_is_guarded_only_with_a_nonzero_notice_and_nothing_pending() {
    let clock = clock_at(0);
    let mut set = new_witness_set(0);
    assert!(!set.is_guarded());

    set.schedule_add(@0xA, &clock);
    set.schedule_delay(10, &clock);
    set.apply_delay(&clock);
    assert!(!set.is_guarded());

    set.apply_add(@0xA, &clock);
    assert!(set.is_guarded());

    set.schedule_delay(0, &clock);
    assert!(!set.is_guarded());

    set.cancel_delay();
    set.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_set_accepts_the_ceiling_notice() {
    let set = new_witness_set(delayed::max_delay_ms());

    assert_eq!(set.delay_ms(), delayed::max_delay_ms());
    set.destroy();
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

fun new_witness_set(delay_ms: u64): DelayedSet<Witnesses, address> {
    let uid = owner_uid();
    let set = delayed_set::new(Witnesses(), &uid, delay_ms);
    uid.delete();
    set
}

fun collect<Event: copy + drop>(): Event {
    let mut events = sui::event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{
    delayed,
    delayed_set::{
        Self,
        DelayedSet,
        MemberRemoved,
        SetApplied,
        SetCancelled,
        SetDestroyed,
    },
    errors,
};

use std::unit_test::assert_eq;

use sui::clock::{Self, Clock};
