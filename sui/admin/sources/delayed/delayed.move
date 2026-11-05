// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Settings that change only after their applied delay, and the deadline rules every
/// delayed type shares.
///
/// A timelock in the Compound/OpenZeppelin sense: schedule, wait the applied delay, then
/// apply; cancellable until applied. Settings live here; one-shot actions in
/// `delayed_action`, allowlists in `delayed_set` and keyed values in `delayed_map`.
///
/// Every value carries an owner-defined key `K` and the ID of the object that stores it.
/// Constructors take that object's `&UID`, which only the code creating or holding the
/// object has, so no package can attribute a value or its events to another's object.
/// Owners use a struct without a public constructor as `K`, so only their module can pack
/// it. Each delayed module emits every lifecycle fact of its type, generic in `K` and
/// carrying `owner`; owners emit only their own side effects.
///
/// Every change, a shorter delay included, waits the delay applied when it was scheduled.
/// A delay can start at zero, so a schedule and its apply in one transaction then act as a
/// setter; there is no other mutation path. No delay exceeds `max_delay_ms`, so a delay
/// can always be changed again. Readers need no Clock.
module blast_admin::delayed;

// === Public Types ===

/// An applied setting, its applied delay and at most one proposed replacement.
public struct Delayed<K: copy + drop + store, T: copy + drop + store> has store {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
    pending: Option<Proposal<T>>,
}

/// A proposed value and the delay in force once it applies, ready from `ready_at_ms`.
public struct Proposal<T: copy + drop + store> has copy, drop, store {
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A delay period and the time it elapses: the delay an admission or entry change waits,
/// or a proposed next delay. Either is ready from `ready_at_ms`.
public struct PendingDelay has copy, drop, store {
    delay_ms: u64,
    ready_at_ms: u64,
}

// === Public Functions ===

/// A setting in force at once; every later change waits the applied delay.
public fun new<K: copy + drop + store, T: copy + drop + store>(
    key: K,
    owner: &UID,
    value: T,
    delay_ms: u64,
): Delayed<K, T> {
    assert_delay(delay_ms);
    let owner = owner.to_inner();

    sui::event::emit(DelayedCreated { owner, key, value, delay_ms });

    Delayed { owner, key, value, delay_ms, pending: option::none() }
}

/// The longest delay any delayed type accepts, in milliseconds.
public fun max_delay_ms(): u64 {
    MAX_DELAY_MS
}

/// The applied value.
public fun value<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): T {
    self.value
}

/// The applied delay in milliseconds.
public fun delay_ms<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): u64 {
    self.delay_ms
}

/// True when every change still to come waits a nonzero delay: the applied delay is nonzero
/// and no proposal would set it to zero.
public fun is_guarded<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): bool {
    self.delay_ms > 0 && self.pending.is_none_or!(|proposal| proposal.delay_ms > 0)
}

/// The proposed replacement, if any.
public fun pending<K: copy + drop + store, T: copy + drop + store>(
    self: &Delayed<K, T>,
): Option<Proposal<T>> {
    self.pending
}

/// Proposes `value` and the next delay `delay_ms`, ready after the applied delay, and
/// returns when. A replaced proposal is cancelled and the full applied delay restarts.
/// Aborts when the proposal would change neither the value nor the delay.
public fun schedule<K: copy + drop + store, T: copy + drop + store>(
    self: &mut Delayed<K, T>,
    value: T,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(value != self.value || delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    let ready_at_ms = ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_replaced();
    self.pending.fill(Proposal { value, delay_ms, ready_at_ms });

    sui::event::emit(DelayedScheduled { owner: self.owner, key: self.key, value, delay_ms, ready_at_ms });

    ready_at_ms
}

/// Proposes only a new value, keeping the applied delay.
public fun schedule_value<K: copy + drop + store, T: copy + drop + store>(
    self: &mut Delayed<K, T>,
    value: T,
    clock: &Clock,
): u64 {
    let delay_ms = self.delay_ms;
    self.schedule(value, delay_ms, clock)
}

/// Proposes only a new delay, keeping the applied value. A shorter delay, zero included,
/// still waits the applied one.
public fun schedule_delay<K: copy + drop + store, T: copy + drop + store>(
    self: &mut Delayed<K, T>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    let value = self.value;
    self.schedule(value, delay_ms, clock)
}

/// Checks that `apply` would succeed now, changing nothing. Owners call it before
/// settling accrued economics under the applied value in the same transaction.
public fun assert_ready<K: copy + drop + store, T: copy + drop + store>(
    self: &Delayed<K, T>,
    clock: &Clock,
) {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    let proposal = self.pending.borrow();
    assert_ready_at(proposal.ready_at_ms, proposal.delay_ms, clock);
}

/// Applies the ready proposal's value and delay together and returns the new value.
public fun apply<K: copy + drop + store, T: copy + drop + store>(
    self: &mut Delayed<K, T>,
    clock: &Clock,
): T {
    self.assert_ready(clock);

    let Proposal { value, delay_ms, ready_at_ms: _ } = self.pending.extract();
    let previous_value = self.value;
    self.value = value;
    self.delay_ms = delay_ms;

    sui::event::emit(DelayedApplied {
        owner: self.owner,
        key: self.key,
        previous_value,
        value,
        delay_ms,
    });

    value
}

/// Discards the proposal, even a ready one, leaving the applied value and delay.
public fun cancel<K: copy + drop + store, T: copy + drop + store>(self: &mut Delayed<K, T>) {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    self.cancel_replaced();
}

/// Deletes a setting with no proposal and records its end; cancel a proposal first.
public fun destroy<K: copy + drop + store, T: copy + drop + store>(self: Delayed<K, T>) {
    assert!(self.pending.is_none(), blast_admin::errors::proposal_pending!());

    let Delayed { owner, key, value: _, delay_ms: _, pending: _ } = self;

    sui::event::emit(DelayedDestroyed<K, T> { owner, key });
}

/// The proposed value, or the proposed change for an action slot.
public fun proposal_value<T: copy + drop + store>(self: &Proposal<T>): T { self.value }

/// The delay in force once the proposal applies.
public fun proposal_delay_ms<T: copy + drop + store>(self: &Proposal<T>): u64 { self.delay_ms }

/// The Unix millisecond time from which the proposal can apply.
public fun ready_at_ms<T: copy + drop + store>(self: &Proposal<T>): u64 { self.ready_at_ms }

/// The delay waited, or the proposed next delay.
public fun pending_delay_ms(self: &PendingDelay): u64 { self.delay_ms }

/// The Unix millisecond time from which the change can apply.
public fun pending_delay_ready_at_ms(self: &PendingDelay): u64 { self.ready_at_ms }

/// The ID of the object that stores this setting.
public fun owner<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): ID {
    self.owner
}

/// The owner-defined key of this setting.
public fun key<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): K {
    self.key
}

/// Whether `apply` would succeed now: a proposal is pending, its `ready_at_ms` has passed, and
/// its delay still fits in a Unix millisecond timestamp.
public fun is_ready<K: copy + drop + store, T: copy + drop + store>(
    self: &Delayed<K, T>,
    clock: &Clock,
): bool {
    self.pending.is_some_and!(|proposal| is_ready_at(proposal.ready_at_ms, proposal.delay_ms, clock))
}

// === Package Functions ===

/// A proposal for another delayed module, built from an already checked deadline.
public(package) fun new_proposal<T: copy + drop + store>(
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
): Proposal<T> {
    Proposal { value, delay_ms, ready_at_ms }
}

/// A delay for another delayed module, built from an already checked deadline.
public(package) fun new_pending_delay(delay_ms: u64, ready_at_ms: u64): PendingDelay {
    PendingDelay { delay_ms, ready_at_ms }
}

/// Rejects a delay longer than `max_delay_ms`.
public(package) fun assert_delay(delay_ms: u64) {
    assert!(delay_ms <= MAX_DELAY_MS, blast_admin::errors::invalid_delay!());
}

/// The deadline `applied_delay_ms` from now; checks that `next_delay_ms` is within the
/// ceiling and stays representable.
public(package) fun ready_at_ms_after(
    applied_delay_ms: u64,
    next_delay_ms: u64,
    clock: &Clock,
): u64 {
    assert_delay(next_delay_ms);
    let ready_at_ms = clock.timestamp_ms().checked_add(applied_delay_ms)
        .destroy_or!(abort blast_admin::errors::invalid_delay!());
    assert!(ready_at_ms.checked_add(next_delay_ms).is_some(), blast_admin::errors::invalid_delay!());

    ready_at_ms
}

/// Whether a change ready from `ready_at_ms` with next delay `next_delay_ms` applies now; the
/// predicate form of `assert_ready_at`.
public(package) fun is_ready_at(ready_at_ms: u64, next_delay_ms: u64, clock: &Clock): bool {
    clock.timestamp_ms() >= ready_at_ms && clock.timestamp_ms().checked_add(next_delay_ms).is_some()
}

/// Checks readiness and rechecks representability at the actual application time.
public(package) fun assert_ready_at(ready_at_ms: u64, next_delay_ms: u64, clock: &Clock) {
    assert!(clock.timestamp_ms() >= ready_at_ms, blast_admin::errors::not_ready!());
    assert!(
        clock.timestamp_ms().checked_add(next_delay_ms).is_some(),
        blast_admin::errors::invalid_delay!(),
    );
}

// === Private Functions ===

fun cancel_replaced<K: copy + drop + store, T: copy + drop + store>(self: &mut Delayed<K, T>) {
    if (self.pending.is_none()) return;
    let Proposal { value, delay_ms, ready_at_ms } = self.pending.extract();

    sui::event::emit(DelayedCancelled { owner: self.owner, key: self.key, value, delay_ms, ready_at_ms });
}

// === Test-Only Functions ===

#[test_only]
public fun delayed_created_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedCreated<K, T>,
): (ID, K, T, u64) {
    (self.owner, self.key, self.value, self.delay_ms)
}

#[test_only]
public fun delayed_scheduled_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedScheduled<K, T>,
): (ID, K, T, u64, u64) {
    (self.owner, self.key, self.value, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun delayed_cancelled_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedCancelled<K, T>,
): (ID, K, T, u64, u64) {
    (self.owner, self.key, self.value, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun delayed_applied_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedApplied<K, T>,
): (ID, K, T, T, u64) {
    (self.owner, self.key, self.previous_value, self.value, self.delay_ms)
}

#[test_only]
public fun delayed_destroyed_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedDestroyed<K, T>,
): (ID, K) {
    (self.owner, self.key)
}

// === Events ===

/// A setting was created with its first applied value and delay.
public struct DelayedCreated<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
}

/// A replacement value and next delay were proposed, ready from `ready_at_ms`.
public struct DelayedScheduled<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposal was discarded, by cancellation or by a replacing schedule.
public struct DelayedCancelled<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A ready proposal became the applied value and delay.
public struct DelayedApplied<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    previous_value: T,
    value: T,
    delay_ms: u64,
}

/// A setting was deleted with nothing pending.
public struct DelayedDestroyed<K: copy + drop + store, phantom T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
}

// === Constants ===

/// The longest delay any delayed value, action, set or map accepts: 30 days.
const MAX_DELAY_MS: u64 = 30 * 24 * 60 * 60 * 1_000;

// === Imports ===

public use fun proposal_value as Proposal.value;
public use fun proposal_delay_ms as Proposal.delay_ms;
public use fun pending_delay_ms as PendingDelay.delay_ms;
public use fun pending_delay_ready_at_ms as PendingDelay.ready_at_ms;

use sui::clock::Clock;
