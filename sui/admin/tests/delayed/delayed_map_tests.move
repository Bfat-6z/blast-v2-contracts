// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_map_tests;

// === Constants ===

const NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct Overrides() has copy, drop, store;

// === Tests ===

#[test]
fun an_entry_waits_the_applied_notice_and_reads_stay_applied_until_apply() {
    let mut clock = clock_at(5);
    let mut map = new_map(NOTICE_MS);
    let (_, _, created_delay_ms) = collect<MapCreated<Overrides, address, u64>>().map_created_fields();
    assert_eq!(created_delay_ms, NOTICE_MS);

    assert_eq!(map.schedule(@0xA, option::some(7), &clock), 5 + NOTICE_MS);
    let (owner, _, change, delay_ms, ready_at_ms) = collect<MapScheduled<Overrides, address, u64>>()
        .map_scheduled_fields();
    assert_eq!(owner, owner());
    assert_eq!(change.changed_entry(), option::some(@0xA));
    assert_eq!(change.changed_value(), option::some(7));
    assert_eq!(delay_ms, NOTICE_MS);
    assert_eq!(ready_at_ms, 5 + NOTICE_MS);

    clock.set_for_testing(5 + NOTICE_MS);
    assert!(map.value(&@0xA).is_none());
    map.apply(@0xA, &clock);
    assert_eq!(map.value(&@0xA), option::some(7));
    assert!(map.pending(&@0xA).is_none());
    let (_, _, applied_change, applied_delay_ms) = collect<MapApplied<Overrides, address, u64>>()
        .map_applied_fields();
    assert_eq!(applied_change.changed_value(), option::some(7));
    assert_eq!(applied_delay_ms, NOTICE_MS);

    clear(&mut map, @0xA, &mut clock);
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun clearing_is_a_delayed_change_that_removes_the_entry() {
    let mut clock = clock_at(0);
    let mut map = new_map(0);
    map.schedule(@0xA, option::some(7), &clock);
    map.apply(@0xA, &clock);
    map.schedule_delay(100, &clock);
    map.apply_delay(&clock);

    assert_eq!(map.schedule(@0xA, option::none(), &clock), 100);
    assert_eq!(map.value(&@0xA), option::some(7));
    clock.set_for_testing(100);
    map.apply(@0xA, &clock);

    assert!(map.value(&@0xA).is_none());
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun zero_notice_entries_apply_at_once_and_raising_the_notice_covers_every_entry() {
    let mut clock = clock_at(3);
    let mut map = new_map(0);
    map.schedule(@0xA, option::some(1), &clock);
    map.apply(@0xA, &clock);
    map.schedule_delay(NOTICE_MS, &clock);
    map.apply_delay(&clock);

    assert_eq!(map.schedule(@0xA, option::some(2), &clock), 3 + NOTICE_MS);
    assert_eq!(map.schedule(@0xB, option::some(3), &clock), 3 + NOTICE_MS);

    map.cancel(@0xA);
    map.cancel(@0xB);
    clear(&mut map, @0xA, &mut clock);
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun pending_entries_keep_their_deadlines_across_notice_changes() {
    let mut clock = clock_at(0);
    let mut map = new_map(100);
    map.schedule(@0xA, option::some(1), &clock);
    map.schedule_delay(1_000, &clock);
    clock.set_for_testing(100);
    map.apply_delay(&clock);

    let pending = map.pending(&@0xA).destroy_some();
    assert_eq!(pending.value(), option::some(1));
    assert_eq!(pending.notice().delay_ms(), 100);
    assert_eq!(pending.notice().ready_at_ms(), 100);
    map.apply(@0xA, &clock);
    assert_eq!(map.schedule(@0xB, option::some(2), &clock), 1_100);

    map.cancel(@0xB);
    clear(&mut map, @0xA, &mut clock);
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun a_replaced_entry_change_is_cancelled_first_and_restarts_the_notice() {
    let mut clock = clock_at(0);
    let mut map = new_map(100);
    map.schedule(@0xA, option::some(1), &clock);
    clock.set_for_testing(40);

    assert_eq!(map.schedule(@0xA, option::some(2), &clock), 140);

    let (_, _, change, delay_ms, ready_at_ms) = collect<MapCancelled<Overrides, address, u64>>()
        .map_cancelled_fields();
    assert_eq!(change.changed_value(), option::some(1));
    assert_eq!(delay_ms, 100);
    assert_eq!(ready_at_ms, 100);

    map.cancel(@0xA);
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun a_ready_entry_change_can_still_be_cancelled() {
    let mut clock = clock_at(0);
    let mut map = new_map(10);
    map.schedule(@0xA, option::some(1), &clock);
    clock.set_for_testing(10);

    map.cancel(@0xA);

    assert!(map.value(&@0xA).is_none());
    assert!(map.pending(&@0xA).is_none());
    destroy(map);
    clock.destroy_for_testing();
}

#[test]
fun an_applied_notice_change_records_the_new_notice() {
    let mut clock = clock_at(0);
    let mut map = new_map(10);
    map.schedule_delay(20, &clock);
    clock.set_for_testing(10);

    map.apply_delay(&clock);

    let (_, _, change, delay_ms) = collect<MapApplied<Overrides, address, u64>>().map_applied_fields();
    assert!(change.changed_entry().is_none());
    assert_eq!(delay_ms, 20);
    assert_eq!(map.delay_ms(), 20);
    destroy(map);
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_map)]
fun scheduling_the_applied_value_rejects() {
    let clock = clock_at(0);
    let mut map = new_map(0);
    map.schedule(@0xA, option::some(1), &clock);
    map.apply(@0xA, &clock);

    map.schedule(@0xA, option::some(1), &clock);

    abort
}

#[test, expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_map)]
fun clearing_an_absent_entry_rejects() {
    let clock = clock_at(0);
    let mut map = new_map(0);

    map.schedule(@0xA, option::none(), &clock);

    abort
}

#[test, expected_failure(abort_code = errors::EUnchanged, location = blast_admin::delayed_map)]
fun proposing_the_applied_notice_rejects() {
    let clock = clock_at(0);
    let mut map = new_map(10);

    map.schedule_delay(10, &clock);

    abort
}

#[test, expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed_map)]
fun an_entry_change_cannot_apply_early() {
    let mut clock = clock_at(0);
    let mut map = new_map(10);
    map.schedule(@0xA, option::some(1), &clock);

    clock.set_for_testing(9);
    map.apply(@0xA, &clock);

    abort
}

#[test, expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun a_notice_change_cannot_apply_early() {
    let mut clock = clock_at(0);
    let mut map = new_map(10);
    map.schedule_delay(0, &clock);

    clock.set_for_testing(9);
    map.apply_delay(&clock);

    abort
}

#[test, expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_map)]
fun applying_an_unscheduled_entry_rejects() {
    let clock = clock_at(0);
    let mut map = new_map(10);

    map.apply(@0xA, &clock);

    abort
}

#[test, expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_map)]
fun cancelling_an_unscheduled_entry_rejects() {
    let mut map = new_map(10);

    map.cancel(@0xA);

    abort
}

#[test, expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_map)]
fun cancelling_a_missing_notice_change_rejects() {
    let mut map = new_map(10);

    map.cancel_delay();

    abort
}

#[test, expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun scheduling_rejects_an_overflowing_deadline() {
    let clock = clock_at(std::u64::max_value!() - 1);
    let mut map = new_map(2);

    map.schedule(@0xA, option::some(1), &clock);

    abort
}

#[test, expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun creation_rejects_a_notice_above_the_ceiling() {
    let map = new_map(delayed::max_delay_ms() + 1);

    destroy(map);

    abort
}

#[test, expected_failure(abort_code = errors::EInvalidDelay, location = blast_admin::delayed)]
fun a_proposed_notice_above_the_ceiling_rejects() {
    let clock = clock_at(0);
    let mut map = new_map(10);

    map.schedule_delay(delayed::max_delay_ms() + 1, &clock);

    abort
}

#[test]
fun a_map_accepts_the_ceiling_notice() {
    let map = new_map(delayed::max_delay_ms());

    assert_eq!(map.delay_ms(), delayed::max_delay_ms());
    destroy(map);
}

#[test]
fun destroying_a_map_ends_its_remaining_entries_and_records_the_end() {
    let clock = clock_at(0);
    let mut map = new_map(0);
    map.schedule(@0xA, option::some(7), &clock);
    map.apply(@0xA, &clock);

    map.destroy();

    let (destroyed_owner, destroyed_key) = collect<MapDestroyed<Overrides, address, u64>>()
        .map_destroyed_fields();
    assert_eq!(destroyed_owner, owner());
    assert_eq!(destroyed_key, Overrides());
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed_map)]
fun a_map_with_a_pending_entry_change_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut map = new_map(NOTICE_MS);
    map.schedule(@0xA, option::some(7), &clock);

    map.destroy();

    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = errors::EProposalPending, location = blast_admin::delayed_map)]
fun a_map_with_a_pending_notice_change_cannot_be_destroyed() {
    let clock = clock_at(0);
    let mut map = new_map(NOTICE_MS);
    map.schedule_delay(1, &clock);

    map.destroy();

    clock.destroy_for_testing();
}

#[test]
fun readers_report_owner_key_counts_and_guard() {
    let mut clock = clock_at(0);
    let mut map = new_map(0);
    assert!(!map.is_guarded());
    map.schedule(@0xA, option::some(1), &clock);
    map.apply(@0xA, &clock);
    map.schedule_delay(NOTICE_MS, &clock);
    map.apply_delay(&clock);

    assert_eq!(map.owner(), owner());
    assert_eq!(map.key(), Overrides());
    assert!(map.contains(&@0xA));
    assert!(!map.contains(&@0xB));
    assert_eq!(map.entry_count(), 1);
    assert_eq!(map.pending_count(), 0);
    assert!(map.is_guarded());

    map.schedule(@0xB, option::some(2), &clock);
    assert_eq!(map.pending_count(), 1);
    assert!(!map.is_guarded());

    map.cancel(@0xB);
    clear(&mut map, @0xA, &mut clock);
    map.destroy();
    clock.destroy_for_testing();
}

#[test]
fun readers_report_pending_and_ready_entry_changes_and_notice_changes() {
    let mut clock = clock_at(0);
    let mut map = new_map(NOTICE_MS);
    map.schedule(@0xA, option::some(3), &clock);
    map.schedule_delay(25, &clock);

    assert!(map.is_pending(&@0xA));
    assert!(!map.is_pending(&@0xB));
    assert_eq!(map.entry_ready_at_ms(&@0xA), option::some(NOTICE_MS));
    assert!(map.entry_ready_at_ms(&@0xB).is_none());
    let proposal = map.pending(&@0xA).destroy_some();
    assert_eq!(proposal.value(), option::some(3));
    assert_eq!(proposal.notice().delay_ms(), NOTICE_MS);
    assert!(!map.is_ready(&@0xA, &clock));
    assert!(!map.is_delay_ready(&clock));
    clock.set_for_testing(NOTICE_MS);
    assert!(map.is_ready(&@0xA, &clock));
    assert!(map.is_delay_ready(&clock));

    map.apply(@0xA, &clock);
    map.apply_delay(&clock);
    assert!(!map.is_pending(&@0xA));
    assert_eq!(map.value(&@0xA), option::some(3));
    assert_eq!(map.delay_ms(), 25);

    clear(&mut map, @0xA, &mut clock);
    map.destroy();
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

fun new_map(delay_ms: u64): DelayedMap<Overrides, address, u64> {
    let mut ctx = tx_context::dummy();
    let uid = object::new(&mut ctx);
    let map = delayed_map::new(Overrides(), &uid, delay_ms, &mut ctx);
    uid.delete();
    map
}

/// Clears `entry` under the applied notice so the map holds no pending change.
fun clear(self: &mut DelayedMap<Overrides, address, u64>, entry: address, clock: &mut Clock) {
    let ready_at_ms = self.schedule(entry, option::none(), clock);
    let now_at_ms = clock.timestamp_ms();
    clock.set_for_testing(ready_at_ms.max(now_at_ms));
    self.apply(entry, clock);
}

fun collect<Event: copy + drop>(): Event {
    let mut events = sui::event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{
    delayed,
    delayed_map::{
        Self,
        DelayedMap,
        MapApplied,
        MapCancelled,
        MapCreated,
        MapDestroyed,
        MapScheduled,
    },
    errors,
};

use std::unit_test::{assert_eq, destroy};

use sui::clock::{Self, Clock};
