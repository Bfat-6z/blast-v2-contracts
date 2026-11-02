// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Explicitly applied changes whose notice period is supplied by the owning policy.
module blast_admin::delayed;

// === Errors ===

#[error(code = 0)]
const ENotReady: vector<u8> = b"The full administrative delay must pass before applying a change.";

#[error(code = 1)]
const ENoPending: vector<u8> = b"There is no scheduled administrative change.";

#[error(code = 2)]
const EInvalidDelay: vector<u8> = b"The notice period must fit a Unix millisecond execution threshold.";

#[error(code = 3)]
const EDelayUnchanged: vector<u8> = b"A notice-period update must change the applied delay.";

// === Public Types ===

/// Applied value with at most one replacement; readers never need a Clock.
public struct Delayed<T: copy + drop + store> has store {
    value: T,
    pending: Option<Pending<T>>,
}

/// A value bound to a Unix millisecond execution threshold.
public struct Pending<T: copy + drop + store> has copy, drop, store {
    value: T,
    ready_at_ms: u64,
}

// === Public Functions ===

/// Initializes publication policy, with no scheduled change.
public fun new<T: copy + drop + store>(value: T): Delayed<T> {
    Delayed { value, pending: option::none() }
}

/// Returns the explicitly applied value.
public fun value<T: copy + drop + store>(self: &Delayed<T>): T {
    self.value
}

/// Borrows the applied value for internal consumers such as signature verification.
public fun borrow<T: copy + drop + store>(self: &Delayed<T>): &T {
    &self.value
}

/// Returns the current schedule, if any.
public fun pending<T: copy + drop + store>(self: &Delayed<T>): Option<Pending<T>> {
    self.pending
}

/// Replaces any pending change and restarts the supplied policy delay.
/// The enclosing module must derive `delay_ms` from its authorized policy.
public fun schedule<T: copy + drop + store>(self: &mut Delayed<T>, value: T, delay_ms: u64, clock: &Clock): u64 {
    let pending = new_pending(value, delay_ms, clock);
    self.pending = option::some(pending);
    pending.ready_at_ms
}

/// Schedules a notice-period change using its currently applied delay, including zero.
/// The enclosing module must restrict this operation to its delay-policy authority.
public fun schedule_delay(self: &mut Delayed<u64>, delay_ms: u64, clock: &Clock): u64 {
    let current_delay_ms = self.value;
    assert!(delay_ms != current_delay_ms, EDelayUnchanged);
    let pending = new_pending(delay_ms, current_delay_ms, clock);
    assert!(delay_ms <= std::u64::max_value!() - pending.ready_at_ms, EInvalidDelay);
    self.pending = option::some(pending);
    pending.ready_at_ms
}

/// Applies a ready delay only while it can still form a future execution threshold.
public fun apply_delay(self: &mut Delayed<u64>, clock: &Clock): u64 {
    assert!(self.pending.is_some(), ENoPending);
    let delay_ms = self.pending.destroy_some().take_ready(clock);
    assert!(delay_ms <= std::u64::max_value!() - clock.timestamp_ms(), EInvalidDelay);
    self.apply(clock)
}

/// Applies a ready change once; anyone authorized to borrow the enclosing state may call it.
public fun apply<T: copy + drop + store>(self: &mut Delayed<T>, clock: &Clock): T {
    assert!(self.pending.is_some(), ENoPending);
    let value = self.pending.destroy_some().take_ready(clock);
    self.pending = option::none();
    self.value = value;
    value
}

/// Cancels even a ready change and returns the cancelled value.
public fun cancel<T: copy + drop + store>(self: &mut Delayed<T>): T {
    assert!(self.pending.is_some(), ENoPending);
    self.pending.extract().value
}

/// Only publication bootstrap or the enclosing module's authority-reducing paths may expose this operation.
/// Clears a pending replacement so it cannot restore revoked authority.
public fun set_now<T: copy + drop + store>(self: &mut Delayed<T>, value: T) {
    self.value = value;
    self.pending = option::none();
}

/// Snapshots the owning policy's notice period into an immutable deadline.
/// Later policy changes cannot shorten or extend this pending value's notice.
public fun new_pending<T: copy + drop + store>(value: T, delay_ms: u64, clock: &Clock): Pending<T> {
    let scheduled_at_ms = clock.timestamp_ms();
    assert!(delay_ms <= std::u64::max_value!() - scheduled_at_ms, EInvalidDelay);
    Pending { value, ready_at_ms: scheduled_at_ms + delay_ms }
}

/// Returns a scheduled value only at or after its threshold.
public fun take_ready<T: copy + drop + store>(self: Pending<T>, clock: &Clock): T {
    assert!(clock.timestamp_ms() >= self.ready_at_ms, ENotReady);
    self.value
}

/// Returns the proposed value for cancellation events and diagnostics.
public fun proposed<T: copy + drop + store>(self: &Pending<T>): T { self.value }

/// Returns the Unix millisecond threshold for a scheduling event.
public fun ready_at_ms<T: copy + drop + store>(self: &Pending<T>): u64 { self.ready_at_ms }

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing<T: copy + drop + store>(self: Delayed<T>) {
    let Delayed { value: _, pending: _ } = self;
}

// === Imports ===

use sui::clock::Clock;
