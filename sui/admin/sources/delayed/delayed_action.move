// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// One-shot actions, such as an upgrade or a capability reassignment, that run only after
/// their slot's applied notice. The slot also governs its own notice. See `delayed` for
/// the rules every delayed type shares.
module blast_admin::delayed_action;

// === Public Types ===

/// An applied notice and at most one proposed one-shot action or notice change.
public struct DelayedAction<K: copy + drop + store, A: copy + drop + store> has store {
    owner: ID,
    key: K,
    delay_ms: u64,
    pending: Option<Proposal<Change<A>>>,
}

/// What a proposal does once applied.
public enum Change<A: copy + drop + store> has copy, drop, store {
    /// Hands the owner its action; the notice stays as applied.
    Action(A),
    /// Changes only the notice, to the proposal's `delay_ms`.
    Delay,
}

// === Public Functions ===

/// An action slot with nothing proposed; every action waits the applied notice.
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

/// True when every action still to come waits a nonzero notice: the applied notice is nonzero
/// and no proposal would set it to zero.
public fun is_guarded<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): bool {
    self.delay_ms > 0 && self.pending.is_none_or!(|proposal| proposal.proposal_delay_ms() > 0)
}

/// The proposed action or notice change, if any.
public fun pending<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): Option<Proposal<Change<A>>> {
    self.pending
}

/// Proposes `action`, ready after the applied notice, and returns when. A replaced
/// proposal is cancelled and the full applied notice restarts.
public fun schedule<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    action: A,
    clock: &Clock,
): u64 {
    let delay_ms = self.delay_ms;
    self.propose(Change::Action(action), delay_ms, clock)
}

/// Proposes only a new notice, ready after the applied one, replacing any proposed action.
public fun schedule_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    self.propose(Change::Delay, delay_ms, clock)
}

/// Consumes the ready proposed action and returns it for the owner to perform.
/// Aborts when the proposal is a notice change.
public fun take_action<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
): A {
    let change = self.take_ready(true, clock);

    change.action().destroy_some()
}

/// Applies the ready proposed notice. Aborts when the proposal is an action.
public fun apply_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
) {
    self.take_ready(false, clock);
}

/// Discards the proposal, even a ready one, leaving the applied notice.
public fun cancel<K: copy + drop + store, A: copy + drop + store>(self: &mut DelayedAction<K, A>) {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    self.cancel_replaced();
}

/// The proposed action, or none for a notice change.
public fun action<A: copy + drop + store>(self: &Change<A>): Option<A> {
    match (self) {
        Change::Action(action) => option::some(*action),
        Change::Delay => option::none(),
    }
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

/// Consumes the ready proposal of the expected kind and commits its notice.
fun take_ready<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    expects_action: bool,
    clock: &Clock,
): Change<A> {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    let proposal = *self.pending.borrow();
    let change = proposal.value();
    assert!(change.action().is_some() == expects_action, blast_admin::errors::wrong_change!());
    delayed::assert_ready_at(proposal.ready_at_ms(), proposal.proposal_delay_ms(), clock);

    self.pending = option::none();
    self.delay_ms = proposal.proposal_delay_ms();

    sui::event::emit(ActionApplied {
        owner: self.owner,
        key: self.key,
        change,
        delay_ms: proposal.proposal_delay_ms(),
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
        delay_ms: proposal.proposal_delay_ms(),
        ready_at_ms: proposal.ready_at_ms(),
    });
}

// === Test-Only Functions ===

#[test_only]
/// The applied notice in milliseconds.
public fun delay_ms<K: copy + drop + store, A: copy + drop + store>(self: &DelayedAction<K, A>): u64 {
    self.delay_ms
}

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

// === Events ===

/// An action slot was created with its first applied notice.
public struct ActionCreated<K: copy + drop + store, phantom A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    delay_ms: u64,
}

/// An action or notice change was proposed, ready from `ready_at_ms`; `delay_ms` is the
/// notice in force once it applies.
public struct ActionScheduled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed action or notice change was discarded, by cancellation or replacement.
public struct ActionCancelled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A ready action was handed to its owner, or a notice change applied.
public struct ActionApplied<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
}

// === Imports ===

use blast_admin::delayed::{Self, Proposal};

use sui::clock::Clock;
