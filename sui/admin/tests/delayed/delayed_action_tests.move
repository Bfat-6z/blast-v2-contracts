// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_action_tests;

// === Constants ===

const DELAY_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct Upgrade() has copy, drop, store;

// === Tests ===

#[test]
fun an_action_waits_the_applied_delay_and_is_handed_back_once() {
    let mut clock = clock_at(5);
    let mut slot = new_slot(DELAY_MS);
    let (_, _, created_delay_ms) = collect<ActionCreated<Upgrade, u64>>().action_created_fields();
    assert_eq!(created_delay_ms, DELAY_MS);

    assert_eq!(slot.schedule(42, &clock), 5 + DELAY_MS);
    let scheduled = collect<ActionScheduled<Upgrade, u64>>();
    let (owner, _, change, delay_ms, ready_at_ms) = scheduled.action_scheduled_fields();
    assert_eq!(owner, owner());
    assert_eq!(change.action(), option::some(42));
    assert_eq!(delay_ms, DELAY_MS);
    assert_eq!(ready_at_ms, 5 + DELAY_MS);

    clock.set_for_testing(5 + DELAY_MS);
    assert_eq!(slot.take_action(&clock), 42);
    let (_, _, applied_change, _) = collect<ActionApplied<Upgrade, u64>>().action_applied_fields();
    assert_eq!(applied_change.action(), option::some(42));
    assert_eq!(slot.delay_ms(), DELAY_MS);
    assert!(slot.pending().is_none());

    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_delay_change_waits_the_applied_delay_and_replaces_a_pending_action() {
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
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_delay_change_cannot_be_taken_as_an_action() {
    let clock = clock_at(0);
    let mut slot = new_slot(0);
    slot.schedule_delay(10, &clock);

    slot.take_action(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed_action)]
fun an_action_cannot_be_applied_as_a_delay_change() {
    let clock = clock_at(0);
    let mut slot = new_slot(0);
    slot.schedule(1, &clock);

    slot.apply_delay(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_action)]
fun proposing_the_applied_delay_rejects() {
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
#[expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed_action)]
fun a_slot_with_a_proposal_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule(1, &clock);

    slot.destroy();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed_action)]
fun the_change_kind_is_checked_before_readiness() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);
    slot.schedule_delay(20, &clock);

    slot.take_action(&clock);

    abort
}

#[test]
fun an_applied_delay_change_records_the_new_delay() {
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
fun destruction_records_the_end_of_the_slot() {
    let slot = new_slot(0);

    slot.destroy();

    let (slot_owner, _) = collect<ActionDestroyed<Upgrade, u64>>().action_destroyed_fields();
    assert_eq!(slot_owner, owner());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun creation_rejects_a_delay_above_the_ceiling() {
    let slot = new_slot(delayed::max_delay_ms() + 1);

    slot.destroy();

    abort
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_delay_above_the_ceiling_rejects() {
    let clock = clock_at(0);
    let mut slot = new_slot(10);

    slot.schedule_delay(delayed::max_delay_ms() + 1, &clock);

    abort
}

#[test]
fun a_slot_is_guarded_only_with_a_nonzero_delay_and_no_zero_delay_proposal() {
    let clock = clock_at(0);
    let mut slot = new_slot(0);
    assert!(!slot.is_guarded());

    slot.schedule_delay(10, &clock);
    slot.apply_delay(&clock);
    assert!(slot.is_guarded());

    slot.schedule(1, &clock);
    assert!(slot.is_guarded());

    slot.schedule_delay(0, &clock);
    assert!(!slot.is_guarded());

    slot.cancel();
    slot.destroy();
    clock.destroy_for_testing();
}

#[test]
fun a_slot_accepts_the_ceiling_delay() {
    let slot = new_slot(delayed::max_delay_ms());

    assert_eq!(slot.delay_ms(), delayed::max_delay_ms());
    slot.destroy();
}

#[test]
fun readers_report_owner_and_key() {
    let slot = new_slot(DELAY_MS);

    assert_eq!(slot.owner(), owner());
    assert_eq!(slot.key(), Upgrade());
    assert_eq!(slot.delay_ms(), DELAY_MS);

    slot.destroy();
}

#[test]
fun readers_split_a_pending_action_from_a_pending_delay_change() {
    let mut clock = clock_at(10);
    let mut slot = new_slot(DELAY_MS);
    assert!(slot.pending_action().is_none());
    assert!(slot.pending_delay().is_none());
    assert!(!slot.is_ready(&clock));

    slot.schedule(5, &clock);
    assert_eq!(slot.pending_action(), option::some(5));
    assert!(slot.pending_delay().is_none());
    clock.set_for_testing(10 + DELAY_MS - 1);
    assert!(!slot.is_ready(&clock));
    clock.set_for_testing(10 + DELAY_MS);
    assert!(slot.is_ready(&clock));
    assert!(!slot.is_delay_ready(&clock));

    slot.schedule_delay(25, &clock);
    let delay = slot.pending_delay().destroy_some();
    assert_eq!(delay.delay_ms(), 25);
    assert_eq!(delay.ready_at_ms(), 10 + 2 * DELAY_MS);
    assert!(slot.pending_action().is_none());
    assert!(!slot.is_delay_ready(&clock));
    clock.set_for_testing(10 + 2 * DELAY_MS);
    assert!(slot.is_delay_ready(&clock));
    assert!(slot.is_ready(&clock));

    slot.cancel();
    slot.destroy();
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

fun new_slot(delay_ms: u64): DelayedAction<Upgrade, u64> {
    let uid = owner_uid();
    let slot = delayed_action::new(Upgrade(), &uid, delay_ms);
    uid.delete();
    slot
}

fun collect<Event: copy + drop>(): Event {
    let mut events = sui::event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{
    delayed,
    delayed_action::{
        Self,
        ActionApplied,
        ActionCancelled,
        ActionCreated,
        ActionDestroyed,
        ActionScheduled,
        DelayedAction,
    },
    errors,
};

use std::unit_test::assert_eq;

use sui::clock::{Self, Clock};
