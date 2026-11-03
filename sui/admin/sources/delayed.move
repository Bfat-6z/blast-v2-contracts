// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Settings, one-shot actions and allowlists that change only after their applied notice.
///
/// A timelock in the Compound/OpenZeppelin sense: schedule, wait the applied notice, then
/// apply; cancellable until applied. It is unrelated to the immutable timelock package,
/// whose values switch by themselves at a deadline.
///
/// Every value carries an owner-defined key `K` and the ID of the object that stores it.
/// Constructors take that object's `&UID`, which only the code creating or holding the
/// object has, so no package can attribute a value or its events to another's object.
/// Owners use a struct without a public constructor as `K`, so only their module can pack
/// it. This module emits every lifecycle fact, generic in `K` and carrying `owner`; owners
/// emit only their own side effects, such as a settlement or a committed upgrade.
///
/// Every change, a shorter notice included, waits the notice applied when it was scheduled.
/// A notice can start at zero, so a schedule and its apply in one transaction then act as a
/// setter; there is no other mutation path. Readers need no Clock.
module blast_admin::delayed;

// === Public Types ===

/// An applied setting, its applied notice and at most one proposed replacement.
public struct Delayed<K: copy + drop + store, T: copy + drop + store> has store {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
    pending: Option<Proposal<T>>,
}

/// An applied notice and at most one proposed one-shot action or notice change.
public struct DelayedAction<K: copy + drop + store, A: copy + drop + store> has store {
    owner: ID,
    key: K,
    delay_ms: u64,
    pending: Option<Proposal<Change<A>>>,
}

/// Members that join only after the applied notice and leave at once. Each admission's
/// deadline is fixed when it is scheduled; a later notice change never moves it.
public struct DelayedSet<K: copy + drop + store, E: copy + drop + store> has store {
    owner: ID,
    key: K,
    members: VecSet<E>,
    delay_ms: u64,
    admissions: VecMap<E, Notice>,
    pending_delay: Option<Notice>,
}

/// A proposed value and the notice in force once it applies, ready from `ready_at_ms`.
public struct Proposal<T: copy + drop + store> has copy, drop, store {
    value: T,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// What a `DelayedAction` proposal does once applied.
public enum Change<A: copy + drop + store> has copy, drop, store {
    /// Hands the owner its action; the notice stays as applied.
    Action(A),
    /// Changes only the notice, to the proposal's `delay_ms`.
    Delay,
}

/// A `DelayedSet` deadline: for an admission, the notice it waits; for a notice change,
/// the proposed next notice. Either is ready from `ready_at_ms`.
public struct Notice has copy, drop, store {
    delay_ms: u64,
    ready_at_ms: u64,
}

// === Public Functions ===

// --- Delayed ---

/// A setting in force at once; every later change waits the applied notice.
public fun new<K: copy + drop + store, T: copy + drop + store>(
    key: K,
    owner: &UID,
    value: T,
    delay_ms: u64,
): Delayed<K, T> {
    let owner = owner.to_inner();

    sui::event::emit(DelayedCreated { owner, key, value, delay_ms });

    Delayed { owner, key, value, delay_ms, pending: option::none() }
}

/// The applied value.
public fun value<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): T {
    self.value
}

/// The applied notice in milliseconds.
public fun delay_ms<K: copy + drop + store, T: copy + drop + store>(self: &Delayed<K, T>): u64 {
    self.delay_ms
}

/// The proposed replacement, if any.
public fun pending<K: copy + drop + store, T: copy + drop + store>(
    self: &Delayed<K, T>,
): Option<Proposal<T>> {
    self.pending
}

/// Proposes `value` and the next notice `delay_ms`, ready after the applied notice, and
/// returns when. A replaced proposal is cancelled and the full applied notice restarts.
/// Aborts when the proposal would change neither the value nor the notice.
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

/// Proposes only a new value, keeping the applied notice.
public fun schedule_value<K: copy + drop + store, T: copy + drop + store>(
    self: &mut Delayed<K, T>,
    value: T,
    clock: &Clock,
): u64 {
    let delay_ms = self.delay_ms;
    self.schedule(value, delay_ms, clock)
}

/// Proposes only a new notice, keeping the applied value. A shorter notice, zero included,
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

/// Applies the ready proposal's value and notice together and returns the new value.
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

/// Discards the proposal, even a ready one, leaving the applied value and notice.
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

// --- DelayedAction ---

/// An action slot with nothing proposed; every action waits the applied notice.
public fun new_action<K: copy + drop + store, A: copy + drop + store>(
    key: K,
    owner: &UID,
    delay_ms: u64,
): DelayedAction<K, A> {
    let owner = owner.to_inner();

    sui::event::emit(ActionCreated<K, A> { owner, key, delay_ms });

    DelayedAction { owner, key, delay_ms, pending: option::none() }
}

/// The applied notice in milliseconds.
public fun action_delay_ms<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): u64 {
    self.delay_ms
}

/// The proposed action or notice change, if any.
public fun action_pending<K: copy + drop + store, A: copy + drop + store>(
    self: &DelayedAction<K, A>,
): Option<Proposal<Change<A>>> {
    self.pending
}

/// Proposes `action`, ready after the applied notice, and returns when. A replaced
/// proposal is cancelled and the full applied notice restarts.
public fun schedule_action<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    action: A,
    clock: &Clock,
): u64 {
    let delay_ms = self.delay_ms;
    self.propose_change(Change::Action(action), delay_ms, clock)
}

/// Proposes only a new notice, ready after the applied one, replacing any proposed action.
public fun schedule_action_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    self.propose_change(Change::Delay, delay_ms, clock)
}

/// Consumes the ready proposed action and returns it for the owner to perform.
/// Aborts when the proposal is a notice change.
public fun take_action<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
): A {
    let change = self.take_ready_change(true, clock);

    change.action().destroy_some()
}

/// Applies the ready proposed notice. Aborts when the proposal is an action.
public fun apply_action_delay<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    clock: &Clock,
) {
    self.take_ready_change(false, clock);
}

/// Discards the proposal, even a ready one, leaving the applied notice.
public fun cancel_action<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
) {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    self.cancel_replaced_change();
}

/// Deletes an action slot with no proposal and records its end; cancel a proposal first.
public fun destroy_action<K: copy + drop + store, A: copy + drop + store>(
    self: DelayedAction<K, A>,
) {
    assert!(self.pending.is_none(), blast_admin::errors::proposal_pending!());

    let DelayedAction { owner, key, delay_ms: _, pending: _ } = self;

    sui::event::emit(ActionDestroyed<K, A> { owner, key });
}

// --- DelayedSet ---

/// An empty set; every admission waits the applied notice.
public fun new_set<K: copy + drop + store, E: copy + drop + store>(
    key: K,
    owner: &UID,
    delay_ms: u64,
): DelayedSet<K, E> {
    let owner = owner.to_inner();

    sui::event::emit(ActionCreated<K, E> { owner, key, delay_ms });

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
public fun delayed_set_members<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): VecSet<E> {
    self.members
}

/// The applied notice for new admissions, in milliseconds.
public fun delayed_set_delay_ms<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
): u64 {
    self.delay_ms
}

/// When `member`'s pending admission becomes ready, if one is pending.
public fun admission_ready_at_ms<K: copy + drop + store, E: copy + drop + store>(
    self: &DelayedSet<K, E>,
    member: &E,
): Option<u64> {
    self.admissions.try_get(member).map!(|admission| admission.ready_at_ms)
}

/// The proposed next notice, if any.
public fun delayed_set_pending_delay<K: copy + drop + store, E: copy + drop + store>(
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
    let ready_at_ms = ready_at_ms_after(self.delay_ms, 0, clock);

    self.cancel_admission_if_pending(member);
    self.admissions.insert(member, Notice { delay_ms: self.delay_ms, ready_at_ms });

    sui::event::emit(ActionScheduled {
        owner: self.owner,
        key: self.key,
        change: Change::Action(member),
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
    assert!(clock.timestamp_ms() >= admission.ready_at_ms, blast_admin::errors::not_ready!());

    self.admissions.remove(&member);
    self.members.insert(member);

    sui::event::emit(ActionApplied {
        owner: self.owner,
        key: self.key,
        change: Change::Action(member),
        delay_ms: admission.delay_ms,
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
public fun schedule_delayed_set_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    let ready_at_ms = ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_delay_if_pending();
    self.pending_delay.fill(Notice { delay_ms, ready_at_ms });

    sui::event::emit(ActionScheduled<K, E> {
        owner: self.owner,
        key: self.key,
        change: Change::Delay,
        delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Applies the ready proposed notice to later admissions.
public fun apply_delayed_set_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    clock: &Clock,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    let Notice { delay_ms, ready_at_ms } = self.pending_delay.extract();
    assert_ready_at(ready_at_ms, delay_ms, clock);

    self.delay_ms = delay_ms;

    sui::event::emit(ActionApplied<K, E> {
        owner: self.owner,
        key: self.key,
        change: Change::Delay,
        delay_ms,
    });
}

/// Discards the proposed notice, even a ready one.
public fun cancel_delayed_set_delay<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    self.cancel_delay_if_pending();
}

/// Deletes a set with no pending admission or notice change and records its end, which
/// also ends every remaining membership.
public fun destroy_delayed_set<K: copy + drop + store, E: copy + drop + store>(self: DelayedSet<K, E>) {
    assert!(
        self.admissions.is_empty() && self.pending_delay.is_none(),
        blast_admin::errors::proposal_pending!(),
    );

    let DelayedSet { owner, key, members: _, delay_ms: _, admissions: _, pending_delay: _ } = self;

    sui::event::emit(ActionDestroyed<K, E> { owner, key });
}

// --- Proposals ---

/// The proposed value, or the proposed change for an action slot.
public fun proposal_value<T: copy + drop + store>(self: &Proposal<T>): T { self.value }

/// The notice in force once the proposal applies.
public fun proposal_delay_ms<T: copy + drop + store>(self: &Proposal<T>): u64 { self.delay_ms }

/// The Unix millisecond time from which the proposal can apply.
public fun ready_at_ms<T: copy + drop + store>(self: &Proposal<T>): u64 { self.ready_at_ms }

/// The proposed action, or none for a notice change.
public fun change_action<A: copy + drop + store>(self: &Change<A>): Option<A> {
    match (self) {
        Change::Action(action) => option::some(*action),
        Change::Delay => option::none(),
    }
}

/// The notice an admission waits, or a proposed next notice.
public fun notice_delay_ms(self: &Notice): u64 { self.delay_ms }

/// The Unix millisecond time from which the admission or notice change can apply.
public fun notice_ready_at_ms(self: &Notice): u64 { self.ready_at_ms }

// === Private Functions ===

/// The deadline `applied_delay_ms` from now; checks that `next_delay_ms` stays representable.
fun ready_at_ms_after(applied_delay_ms: u64, next_delay_ms: u64, clock: &Clock): u64 {
    let ready_at_ms = clock.timestamp_ms().checked_add(applied_delay_ms)
        .destroy_or!(abort blast_admin::errors::invalid_delay!());
    assert!(ready_at_ms.checked_add(next_delay_ms).is_some(), blast_admin::errors::invalid_delay!());

    ready_at_ms
}

/// Rechecks representability at the actual application time.
fun assert_ready_at(ready_at_ms: u64, next_delay_ms: u64, clock: &Clock) {
    assert!(clock.timestamp_ms() >= ready_at_ms, blast_admin::errors::not_ready!());
    assert!(
        clock.timestamp_ms().checked_add(next_delay_ms).is_some(),
        blast_admin::errors::invalid_delay!(),
    );
}

fun cancel_replaced<K: copy + drop + store, T: copy + drop + store>(self: &mut Delayed<K, T>) {
    if (self.pending.is_none()) return;
    let Proposal { value, delay_ms, ready_at_ms } = self.pending.extract();

    sui::event::emit(DelayedCancelled { owner: self.owner, key: self.key, value, delay_ms, ready_at_ms });
}

fun propose_change<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    change: Change<A>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    let ready_at_ms = ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_replaced_change();
    self.pending.fill(Proposal { value: change, delay_ms, ready_at_ms });

    sui::event::emit(ActionScheduled { owner: self.owner, key: self.key, change, delay_ms, ready_at_ms });

    ready_at_ms
}

/// Consumes the ready proposal of the expected kind and commits its notice.
fun take_ready_change<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
    expects_action: bool,
    clock: &Clock,
): Change<A> {
    assert!(self.pending.is_some(), blast_admin::errors::no_pending!());
    let proposal = *self.pending.borrow();
    assert!(proposal.value.action().is_some() == expects_action, blast_admin::errors::wrong_change!());
    assert_ready_at(proposal.ready_at_ms, proposal.delay_ms, clock);

    self.pending = option::none();
    self.delay_ms = proposal.delay_ms;

    sui::event::emit(ActionApplied {
        owner: self.owner,
        key: self.key,
        change: proposal.value,
        delay_ms: proposal.delay_ms,
    });

    proposal.value
}

fun cancel_replaced_change<K: copy + drop + store, A: copy + drop + store>(
    self: &mut DelayedAction<K, A>,
) {
    if (self.pending.is_none()) return;
    let Proposal { value: change, delay_ms, ready_at_ms } = self.pending.extract();

    sui::event::emit(ActionCancelled { owner: self.owner, key: self.key, change, delay_ms, ready_at_ms });
}

fun cancel_admission_if_pending<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
    member: E,
) {
    if (!self.admissions.contains(&member)) return;
    let (_, Notice { delay_ms, ready_at_ms }) = self.admissions.remove(&member);

    sui::event::emit(ActionCancelled {
        owner: self.owner,
        key: self.key,
        change: Change::Action(member),
        delay_ms,
        ready_at_ms,
    });
}

fun cancel_delay_if_pending<K: copy + drop + store, E: copy + drop + store>(
    self: &mut DelayedSet<K, E>,
) {
    if (self.pending_delay.is_none()) return;
    let Notice { delay_ms, ready_at_ms } = self.pending_delay.extract();

    sui::event::emit(ActionCancelled<K, E> {
        owner: self.owner,
        key: self.key,
        change: Change::Delay,
        delay_ms,
        ready_at_ms,
    });
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
public fun delayed_destroyed_fields<K: copy + drop + store, T: copy + drop + store>(
    self: &DelayedDestroyed<K, T>,
): (ID, K) {
    (self.owner, self.key)
}

#[test_only]
public fun action_destroyed_fields<K: copy + drop + store, A: copy + drop + store>(
    self: &ActionDestroyed<K, A>,
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

/// A `Delayed` setting was created with its first applied value and notice.
public struct DelayedCreated<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    value: T,
    delay_ms: u64,
}

/// A replacement value and next notice were proposed, ready from `ready_at_ms`.
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

/// A ready proposal became the applied value and notice.
public struct DelayedApplied<K: copy + drop + store, T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    previous_value: T,
    value: T,
    delay_ms: u64,
}

/// A `DelayedAction` slot or `DelayedSet` was created with its first applied notice.
public struct ActionCreated<K: copy + drop + store, phantom A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    delay_ms: u64,
}

/// An action, admission or notice change was proposed, ready from `ready_at_ms`.
/// `delay_ms` is the notice in force once it applies; for an admission, the notice it waits.
public struct ActionScheduled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed action, admission or notice change was discarded.
public struct ActionCancelled<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A ready action was handed to its owner, a member was admitted, or a notice applied;
/// `delay_ms` matches the proposal's `ActionScheduled`.
public struct ActionApplied<K: copy + drop + store, A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: Change<A>,
    delay_ms: u64,
}

/// A `Delayed` setting was deleted with nothing pending.
public struct DelayedDestroyed<K: copy + drop + store, phantom T: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
}

/// A `DelayedAction` slot or `DelayedSet` was deleted with nothing pending; a set's
/// remaining members leave with it.
public struct ActionDestroyed<K: copy + drop + store, phantom A: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
}

/// A member left a `DelayedSet` at once.
public struct MemberRemoved<K: copy + drop + store, E: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    member: E,
}

// === Imports ===

public use fun action_delay_ms as DelayedAction.delay_ms;
public use fun action_pending as DelayedAction.pending;
public use fun schedule_action as DelayedAction.schedule;
public use fun schedule_action_delay as DelayedAction.schedule_delay;
public use fun apply_action_delay as DelayedAction.apply_delay;
public use fun cancel_action as DelayedAction.cancel;
public use fun destroy_action as DelayedAction.destroy;
public use fun delayed_set_members as DelayedSet.members;
public use fun delayed_set_delay_ms as DelayedSet.delay_ms;
public use fun delayed_set_pending_delay as DelayedSet.pending_delay;
public use fun schedule_delayed_set_delay as DelayedSet.schedule_delay;
public use fun apply_delayed_set_delay as DelayedSet.apply_delay;
public use fun cancel_delayed_set_delay as DelayedSet.cancel_delay;
public use fun destroy_delayed_set as DelayedSet.destroy;
public use fun change_action as Change.action;
public use fun proposal_value as Proposal.value;
public use fun proposal_delay_ms as Proposal.delay_ms;
public use fun notice_delay_ms as Notice.delay_ms;
public use fun notice_ready_at_ms as Notice.ready_at_ms;

use sui::{clock::Clock, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};
