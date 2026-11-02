// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Explicit changes that always wait their operation's currently applied notice period.
module blast_admin::delayed;

// === Public Types ===

/// Applied value and notice period, with at most one atomic replacement.
/// Readers need no Clock. There is no immediate mutation or bypass operation.
public struct Delayed<T: copy + drop + store> has store {
    value: T,
    delay_ms: u64,
    pending: Option<Pending<T>>,
}

/// Proposed value and next notice period, bound to a Unix millisecond threshold.
public struct Pending<T: copy + drop + store> has copy, drop, store {
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
}

// === Public Functions ===

/// Initializes a value and the notice period anchored at each future scheduling time.
public fun new<T: copy + drop + store>(value: T, delay_ms: u64): Delayed<T> {
    Delayed { value, delay_ms, pending: option::none() }
}

/// Returns the explicitly applied value.
public fun value<T: copy + drop + store>(self: &Delayed<T>): T { self.value }

/// Returns this operation's currently applied notice period in milliseconds.
public fun delay_ms<T: copy + drop + store>(self: &Delayed<T>): u64 { self.delay_ms }

/// Returns the current proposal, if any.
public fun pending<T: copy + drop + store>(self: &Delayed<T>): Option<Pending<T>> { self.pending }

/// Replaces the proposal and restarts the full currently applied delay.
/// `delay_ms` is the NEXT notice period, never the wait for this proposal.
public fun schedule<T: copy + drop + store>(self: &mut Delayed<T>, value: T, delay_ms: u64, clock: &Clock): u64 {
    let pending = new_pending(value, self.delay_ms, delay_ms, clock);
    self.pending = option::some(pending);
    pending.ready_at_ms
}

/// Changes only the value, retaining the applied notice period.
public fun schedule_value<T: copy + drop + store>(self: &mut Delayed<T>, value: T, clock: &Clock): u64 {
    let delay_ms = self.delay_ms;
    self.schedule(value, delay_ms, clock)
}

/// Changes only the notice period, retaining the applied value.
/// A reduction, including to zero, still waits the old notice period.
public fun schedule_delay<T: copy + drop + store>(self: &mut Delayed<T>, delay_ms: u64, clock: &Clock): u64 {
    let value = self.value;
    self.schedule(value, delay_ms, clock)
}

/// Applies both proposed fields once, only after the stored deadline.
public fun apply<T: copy + drop + store>(self: &mut Delayed<T>, clock: &Clock): T {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    let (value, delay_ms) = self.pending.destroy_some().take_ready(clock);
    self.pending = option::none();
    self.value = value;
    self.delay_ms = delay_ms;
    value
}

/// Cancels even a ready proposal without changing the applied value or delay.
public fun cancel<T: copy + drop + store>(self: &mut Delayed<T>): T {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    self.pending.extract().value
}

/// Snapshots a standalone operation's applied delay and proposed next delay.
/// Its owner must persist the returned next delay on successful application.
public fun new_pending<T: copy + drop + store>(value: T, current_delay_ms: u64, delay_ms: u64, clock: &Clock): Pending<T> {
    let scheduled_at_ms = clock.timestamp_ms();
    let ready_at_ms = scheduled_at_ms.checked_add(current_delay_ms)
        .destroy_or!(abort blast_admin::errors::invalid_delay!());
    assert!(ready_at_ms.checked_add(delay_ms).is_some(), blast_admin::errors::invalid_delay!());
    Pending { value, delay_ms, ready_at_ms }
}

/// Returns a ready proposal's value and next delay. Rechecks representability at actual application.
/// Future scheduling still checks its own timestamp addition as time advances.
public fun take_ready<T: copy + drop + store>(self: Pending<T>, clock: &Clock): (T, u64) {
    assert!(clock.timestamp_ms() >= self.ready_at_ms, blast_admin::errors::not_ready!());
    assert!(clock.timestamp_ms().checked_add(self.delay_ms).is_some(), blast_admin::errors::invalid_delay!());
    (self.value, self.delay_ms)
}

/// Returns the proposed value for cancellation and diagnostics.
public fun pending_value<T: copy + drop + store>(self: &Pending<T>): T { self.value }

/// Returns the proposed next notice period.
public fun pending_delay_ms<T: copy + drop + store>(self: &Pending<T>): u64 { self.delay_ms }

/// Returns the Unix millisecond execution threshold.
public fun ready_at_ms<T: copy + drop + store>(self: &Pending<T>): u64 { self.ready_at_ms }

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing<T: copy + drop + store>(self: Delayed<T>) {
    let Delayed { value: _, delay_ms: _, pending: _ } = self;
}

// === Imports ===

public use fun pending_value as Pending.value;
public use fun pending_delay_ms as Pending.delay_ms;

use sui::clock::Clock;
