// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Allowlists whose members join only after the applied notice and leave at once. See
/// `delayed` for the rules every delayed type shares.
module blast_admin::delayed_set;

// === Public Types ===

/// Admitted members, one applied notice for new admissions, pending admissions with fixed
/// deadlines, and at most one proposed notice. A notice change never moves a deadline.
public struct DelayedSet<K: copy + drop + store, E: copy + drop + store> has store {
    owner: ID,
    key: K,
    members: VecSet<E>,
    delay_ms: u64,
    admissions: VecMap<E, Notice>,
    pending_delay: Option<Notice>,
}

/// What a set proposal does once applied.
public enum SetChange<E: copy + drop + store> has copy, drop, store {
    /// Admits the member.
    Admission(E),
    /// Changes the notice for later admissions.
    Delay,
}

// === Public Functions ===

/// An empty set; every admission waits the applied notice.
public fun new<K: copy + drop + store, E: copy + drop + store>(
    key: K,
    owner: &UID,
    delay_ms: u64,
): DelayedSet<K, E> {
    delayed::assert_delay(delay_ms);
    let owner = owner.to_inner();

    sui::event::emit(SetCreated<K, E> { owner, key, delay_ms });

    DelayedSet {
        owner,
        key,
        members: vec_set::empty(),
        delay_ms,
        admissions: vec_map::empty(),
        pending_delay: option::none(),
    }
}

/// Whether `member` has been admitted and not removed.
public fun contains<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
): bool {
    self.members.contains(member)
}

/// The admitted members.
public fun members<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): VecSet<E> {
    self.members
}

/// The applied notice for new admissions, in milliseconds.
public fun delay_ms<K: copy + drop + store, E: copy + drop + store>(self: &DelayedSet<K, E>): u64 {
    self.delay_ms
}

/// When `member`'s pending admission becomes ready, if one is pending.
public fun admission_ready_at_ms<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
): Option<u64> {
    self.admissions.try_get(member).map!(|admission| admission.ready_at_ms())
}

/// How many admissions are pending.
public fun pending_count<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): u64 {
    self.admissions.length()
}

/// True when every admission still to come waits a nonzero notice: the applied notice is
/// nonzero, no proposal would set it to zero, and no admission scheduled earlier is pending.
public fun is_guarded<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): bool {
    self.delay_ms > 0
        && self.admissions.is_empty()
        && self.pending_delay.is_none_or!(|notice| notice.notice_delay_ms() > 0)
}

/// The proposed next notice, if any.
public fun pending_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): Option<Notice> {
    self.pending_delay
}

/// Proposes admitting `member` after the applied notice (never a proposed one) and returns
/// when. Rescheduling a pending member cancels its admission and restarts the notice.
/// Aborts when `member` is already admitted.
public fun schedule_add<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
    clock: &Clock,
): u64 {
    assert!(!self.members.contains(&member), blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, 0, clock);

    self.cancel_admission_if_pending(member);
    self.admissions.insert(member, delayed::new_notice(self.delay_ms, ready_at_ms));

    sui::event::emit(SetScheduled {
        owner: self.owner,
        key: self.key,
        change: SetChange::Admission(member),
        delay_ms: self.delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Admits `member` once its admission is ready.
public fun apply_add<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
    clock: &Clock,
) {
    assert!(self.admissions.contains(&member), blast_admin::errors::no_pending!());
    let admission = self.admissions[&member];
    assert!(clock.timestamp_ms() >= admission.ready_at_ms(), blast_admin::errors::not_ready!());

    self.admissions.remove(&member);
    self.members.insert(member);

    sui::event::emit(SetApplied {
        owner: self.owner,
        key: self.key,
        change: SetChange::Admission(member),
        delay_ms: admission.delay_ms(),
    });
}

/// Discards `member`'s pending admission, even a ready one.
public fun cancel_add<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
) {
    assert!(self.admissions.contains(&member), blast_admin::errors::no_pending!());
    self.cancel_admission_if_pending(member);
}

/// Removes `member` at once and discards its pending admission, leaving the notice.
/// Aborts when `member` is neither admitted nor pending.
public fun remove<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
) {
    let is_member = self.members.contains(&member);
    assert!(is_member || self.admissions.contains(&member), blast_admin::errors::unchanged!());

    self.cancel_admission_if_pending(member);
    if (is_member) {
        self.members.remove(&member);
        sui::event::emit(MemberRemoved { owner: self.owner, key: self.key, member });
    };
}

/// Proposes only a new notice, ready after the applied one, and returns when. Pending
/// admissions keep their deadlines.
public fun schedule_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_delay_if_pending();
    self.pending_delay.fill(delayed::new_notice(delay_ms, ready_at_ms));

    sui::event::emit(SetScheduled<K, E> {
        owner: self.owner,
        key: self.key,
        change: SetChange::Delay,
        delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Applies the ready proposed notice to later admissions.
public fun apply_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    clock: &Clock,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    let notice = self.pending_delay.extract();
    delayed::assert_ready_at(notice.ready_at_ms(), notice.delay_ms(), clock);

    self.delay_ms = notice.delay_ms();

    sui::event::emit(SetApplied<K, E> {
        owner: self.owner,
        key: self.key,
        change: SetChange::Delay,
        delay_ms: notice.delay_ms(),
    });
}

/// Discards the proposed notice, even a ready one.
public fun cancel_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    self.cancel_delay_if_pending();
}

/// Deletes a set with no pending admission or notice change and records its end, which
/// also ends every remaining membership.
public fun destroy<K: copy + drop + store, E: copy + drop + store>(self: DelayedSet<K, E>) {
    assert!(
        self.admissions.is_empty() && self.pending_delay.is_none(),
        blast_admin::errors::proposal_pending!(),
    );

    let DelayedSet { owner, key, members: _, delay_ms: _, admissions: _, pending_delay: _ } = self;

    sui::event::emit(SetDestroyed<K, E> { owner, key });
}

/// How many members are admitted.
public fun member_count<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): u64 {
    self.members.length()
}

/// Whether `member` has a pending admission.
public fun is_pending<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
): bool {
    self.admissions.contains(member)
}

/// Whether `member`'s pending admission would apply now.
public fun is_ready<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
    clock: &Clock,
): bool {
    self.admissions.try_get(member).is_some_and!(|admission| {
        clock.timestamp_ms() >= admission.notice_ready_at_ms()
    })
}

/// Whether a pending notice change would apply now.
public fun is_delay_ready<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    clock: &Clock,
): bool {
    self.pending_delay.is_some_and!(|notice| {
        delayed::is_ready_at(notice.notice_ready_at_ms(), notice.notice_delay_ms(), clock)
    })
}

/// The ID of the object that stores this set.
public fun owner<K: copy + drop + store, E: copy + drop + store>(self: &DelayedSet<K, E>): ID {
    self.owner
}

/// The owner-defined key of this set.
public fun key<K: copy + drop + store, E: copy + drop + store>(self: &DelayedSet<K, E>): K {
    self.key
}

/// The notice `member`'s pending admission waits and when it becomes ready, if one is pending.
public fun admission_notice<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
): Option<Notice> {
    self.admissions.try_get(member)
}

/// The member a change admits, or none for a notice change.
public fun member<E: copy + drop + store>(self: &SetChange<E>): Option<E> {
    match (self) {
        SetChange::Admission(member) => option::some(*member),
        SetChange::Delay => option::none(),
    }
}

// === Private Functions ===

fun cancel_admission_if_pending<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
) {
    if (!self.admissions.contains(&member)) return;
    let (_, admission) = self.admissions.remove(&member);

    sui::event::emit(SetCancelled {
        owner: self.owner,
        key: self.key,
        change: SetChange::Admission(member),
        delay_ms: admission.delay_ms(),
        ready_at_ms: admission.ready_at_ms(),
    });
}

fun cancel_delay_if_pending<K: copy + drop + store, E: copy + drop + store>(self: &mut DelayedSet<K, E>) {
    if (self.pending_delay.is_none()) return;
    let notice = self.pending_delay.extract();

    sui::event::emit(SetCancelled<K, E> {
        owner: self.owner,
        key: self.key,
        change: SetChange::Delay,
        delay_ms: notice.delay_ms(),
        ready_at_ms: notice.ready_at_ms(),
    });
}

// === Test-Only Functions ===

#[test_only]
public fun set_created_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &SetCreated<K, E>,
): (ID, K, u64) {
    (self.owner, self.key, self.delay_ms)
}

#[test_only]
public fun set_scheduled_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &SetScheduled<K, E>,
): (ID, K, SetChange<E>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun set_cancelled_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &SetCancelled<K, E>,
): (ID, K, SetChange<E>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun set_applied_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &SetApplied<K, E>,
): (ID, K, SetChange<E>, u64) {
    (self.owner, self.key, self.change, self.delay_ms)
}

#[test_only]
public fun set_destroyed_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &SetDestroyed<K, E>,
): (ID, K) {
    (self.owner, self.key)
}

#[test_only]
public fun member_removed_fields<K: copy + drop + store, E: copy + drop + store>(
    self: &MemberRemoved<K, E>,
): (ID, K, E) {
    (self.owner, self.key, self.member)
}

// === Events ===

/// A set was created empty with its first applied notice.
public struct SetCreated<K: copy + drop + store, phantom E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    delay_ms: u64,
}

/// An admission or notice change was proposed, ready from `ready_at_ms`. `delay_ms` is the
/// notice an admission waits, or the proposed next notice.
public struct SetScheduled<K: copy + drop + store, E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: SetChange<E>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed admission or notice change was discarded, by cancellation, replacement or
/// removal; its fields match its `SetScheduled`.
public struct SetCancelled<K: copy + drop + store, E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: SetChange<E>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A member was admitted, or a notice change applied; `delay_ms` matches its `SetScheduled`.
public struct SetApplied<K: copy + drop + store, E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: SetChange<E>,
    delay_ms: u64,
}

/// A member left the set at once.
public struct MemberRemoved<K: copy + drop + store, E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    member: E,
}

/// A set was deleted with nothing pending; its remaining members leave with it.
public struct SetDestroyed<K: copy + drop + store, phantom E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
}

// === Imports ===

use blast_admin::delayed::{Self, Notice};

use sui::{clock::Clock, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};
