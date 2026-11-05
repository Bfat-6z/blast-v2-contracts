// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// One-shot actions, such as an upgrade or a capability reassignment, that run only after
/// their slot's applied delay. The slot also governs its own delay. See `delayed` for
/// the rules every delayed type shares.
module blast_admin::delayed_action;

// === Public Types ===

/// An applied delay and at most one proposed one-shot action or delay change.
public struct DelayedAction<K: copy + drop + store, A: copy + drop + store> has store {
    owner: ID,
    key: K,
    delay_ms: u64,
    pending: Option<Proposal<Change<A>>>,
}

/// What a proposal does once applied.
public enum Change<A: copy + drop + store> has copy, drop, store {
    /// Hands the owner its action; the delay stays as applied.
    Action(A),
    /// Changes only the delay, to the proposal's `delay_ms`.
    Delay,
}

// === Public Functions ===

/// An action slot with nothing proposed; every action waits the applied delay.
public fun new<K: copy + drop + store, A: copy + drop + store>(
    key: K,
    owner: &UID,
    delay_ms: u64,
): DelayedAction<K, A> {
    delayed::assert_delay(delay_ms);
    let owner = owner.to_inner();

    sui::event::emit(ActionCreated<K, A> { owner, key, delay_ms });

    DelayedAction { owner, key, delay_ms, pending: option::none() }
}

/// The applied delay in milliseconds.
public fun delay_ms<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): u64 {
    self.delay_ms
}

/// True when every action still to come waits a nonzero delay: the applied delay is nonzero
/// and no proposal would set it to zero.
public fun is_guarded<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): bool {
    self.delay_ms > 0 && self.pending.is_none_or!(|proposal| proposal.proposal_delay_ms() > 0)
}

/// The proposed action or delay change, if any.
public fun pending<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): Option<Proposal<Change<A>>> {
    self.pending
}

/// Proposes `action`, ready after the applied delay, and returns when. A replaced
/// proposal is cancelled and the full applied delay restarts.
public fun schedule<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    action: A,
    clock: &Clock,
): u64 {
    let delay_ms = self.delay_ms;
    self.propose(Change::Action(action), delay_ms, clock)
}

/// Proposes only a new delay, ready after the applied one, replacing any proposed action.
public fun schedule_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    self.propose(Change::Delay, delay_ms, clock)
}

/// Consumes the ready proposed action and returns it for the owner to perform.
/// Aborts when the proposal is a delay change.
public fun take_action<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
): A {
    let change = self.take_ready(true, clock);

    change.action().destroy_some()
}

/// Applies the ready proposed delay. Aborts when the proposal is an action.
public fun apply_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
) {
    self.take_ready(false, clock);
}

/// Discards the proposal, even a ready one, leaving the applied delay.
public fun cancel<K: copy + drop + store, A: copy + drop + store>(self: &mut DelayedAction<K, A>) {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    self.cancel_replaced();
}

/// Deletes an action slot with no proposal and records its end; cancel a proposal first.
public fun destroy<K: copy + drop + store, A: copy + drop + store>(self: DelayedAction<K, A>) {
    assert!(self.pending.is_none(), blast_admin::errors::proposal_pending!());

    let DelayedAction { owner, key, delay_ms: _, pending: _ } = self;

    sui::event::emit(ActionDestroyed<K, A> { owner, key });
}

/// The proposed action, or none for a delay change.
public fun action<A: copy + drop + store>(self: &Change<A>): Option<A> {
    match (self) {
        Change::Action(action) => option::some(*action),
        Change::Delay => option::none(),
    }
}

/// The proposed action, or none when nothing or a delay change is pending.
public fun pending_action<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): Option<A> {
    self.pending.and_ref!(|proposal| proposal.value().action())
}

/// The proposed next delay and when it becomes ready, or none when nothing or an action is
/// pending.
public fun pending_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): Option<PendingDelay> {
    self.pending.and_ref!(|proposal| {
        if (proposal.value().action().is_some()) option::none()
        else option::some(delayed::new_pending_delay(proposal.proposal_delay_ms(), proposal.ready_at_ms()))
    })
}

/// Whether the pending proposal, an action or a delay change, would apply now.
public fun is_ready<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
    clock: &Clock,
): bool {
    self.pending.is_some_and!(|proposal| {
        delayed::is_ready_at(proposal.ready_at_ms(), proposal.proposal_delay_ms(), clock)
    })
}

/// Whether a pending delay change would apply now.
public fun is_delay_ready<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
    clock: &Clock,
): bool {
    self.pending_delay().is_some_and!(|delay| {
        delayed::is_ready_at(delay.ready_at_ms(), delay.delay_ms(), clock)
    })
}

/// The ID of the object that stores this action slot.
public fun owner<K: copy + drop + store, A: copy + drop + store>(self: &DelayedAction<K, A>): ID {
    self.owner
}

/// The owner-defined key of this action slot.
public fun key<K: copy + drop + store, A: copy + drop + store>(self: &DelayedAction<K, A>): K {
    self.key
}

// === Private Functions ===

fun propose<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    change: Change<A>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_replaced();
    self.pending.fill(delayed::new_proposal(change, delay_ms, ready_at_ms));

    sui::event::emit(ActionScheduled { owner: self.owner, key: self.key, change, delay_ms, ready_at_ms });

    ready_at_ms
}

/// Consumes the ready proposal of the expected kind and commits its delay.
fun take_ready<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    expects_action: bool,
    clock: &Clock,
): Change<A> {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    let proposal = *self.pending.borrow();
    let change = proposal.value();
    assert!(change.action().is_some() == expects_action, blast_admin::errors::wrong_change!());
    delayed::assert_ready_at(proposal.ready_at_ms(), proposal.delay_ms(), clock);

    self.pending = option::none();
    self.delay_ms = proposal.delay_ms();

    sui::event::emit(ActionApplied {
        owner: self.owner,
        key: self.key,
        change,
        delay_ms: proposal.delay_ms(),
    });

    change
}

fun cancel_replaced<K: copy + drop + store, A: copy + drop + store>(self: &mut DelayedAction<K, A>) {
    if (self.pending.is_none()) return;
    let proposal = self.pending.extract();

    sui::event::emit(ActionCancelled {
        owner: self.owner,
        key: self.key,
        change: proposal.value(),
        delay_ms: proposal.delay_ms(),
        ready_at_ms: proposal.ready_at_ms(),
    });
}

// === Test-Only Functions ===

#[test_only]
public fun action_created_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionCreated<K, A>,
): (ID, K, u64) {
    (self.owner, self.key, self.delay_ms)
}

#[test_only]
public fun action_scheduled_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionScheduled<K, A>,
): (ID, K, Change<A>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun action_cancelled_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionCancelled<K, A>,
): (ID, K, Change<A>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun action_applied_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionApplied<K, A>,
): (ID, K, Change<A>, u64) {
    (self.owner, self.key, self.change, self.delay_ms)
}

#[test_only]
public fun action_destroyed_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionDestroyed<K, A>,
): (ID, K) {
    (self.owner, self.key)
}

// === Events ===

/// An action slot was created with its first applied delay.
public struct ActionCreated<K: copy + drop + store, phantom A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    delay_ms: u64,
}

/// An action or delay change was proposed, ready from `ready_at_ms`; `delay_ms` is the
/// delay in force once it applies.
public struct ActionScheduled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed action or delay change was discarded, by cancellation or replacement.
public struct ActionCancelled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A ready action was handed to its owner, or a delay change applied.
public struct ActionApplied<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
}

/// An action slot was deleted with nothing pending.
public struct ActionDestroyed<K: copy + drop + store, phantom A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
}

// === Imports ===

use blast_admin::delayed::{Self, PendingDelay, Proposal};

use sui::clock::Clock;
