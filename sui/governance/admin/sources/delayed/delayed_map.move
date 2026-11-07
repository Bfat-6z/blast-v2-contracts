// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Keyed values under one shared delay, such as per-coin overrides. Every entry change,
/// setting or clearing, waits the delay applied when it was scheduled, and its deadline is
/// fixed then; a later delay change never moves it. See `delayed` for the shared rules.
module blast_admin::delayed_map;

// === Public Types ===

/// Applied values by entry, one applied delay, at most one pending change per entry, and at
/// most one proposed delay. Values live in a Table, so reads cost one entry and the map
/// grows without bound; pending changes are few and live inline.
public struct DelayedMap<
    K: copy + drop + store,
    E: copy + drop + store,
    V: copy + drop + store,
> has store {
    parent: ID,
    key: K,
    entries: Table<E, V>,
    delay_ms: u64,
    pending: VecMap<E, EntryProposal<V>>,
    pending_delay: Option<PendingDelay>,
}

/// A proposed entry value, or none to clear the entry, and its fixed deadline.
public struct EntryProposal<V: copy + drop + store> has copy, drop, store {
    value: Option<V>,
    deadline: Deadline,
}

/// What a map proposal does once applied.
public enum MapChange<E: copy + drop + store, V: copy + drop + store> has copy, drop, store {
    /// Sets the entry to `value`, or clears it when `value` is none.
    Entry { entry: E, value: Option<V> },
    /// Changes the delay for later entry changes.
    Delay,
}

// === Public Functions ===

/// An empty map; every entry change waits the applied delay.
public fun new<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    key: K,
    parent: &UID,
    delay_ms: u64,
    ctx: &mut TxContext,
): DelayedMap<K, E, V> {
    delayed::assert_delay(delay_ms);
    let parent = parent.to_inner();

    sui::event::emit(MapCreated<K, E, V> { parent, key, delay_ms });

    DelayedMap {
        parent,
        key,
        entries: table::new(ctx),
        delay_ms,
        pending: vec_map::empty(),
        pending_delay: option::none(),
    }
}

/// The applied value of `entry`, or none when it has none.
public fun value<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
): Option<V> {
    if (self.entries.contains(*entry)) option::some(self.entries[*entry]) else option::none()
}

/// The applied delay for entry changes, in milliseconds.
public fun delay_ms<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): u64 {
    self.delay_ms
}

/// The pending change of `entry`, if any.
public fun pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
): Option<EntryProposal<V>> {
    self.pending.try_get(entry)
}

/// The proposed next delay, if any.
public fun pending_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): Option<PendingDelay> {
    self.pending_delay
}

/// Proposes setting `entry` to `value` (none clears it) after the applied delay, and
/// returns when. A replaced change is cancelled and the full delay restarts. Aborts when
/// `value` is already the applied value.
public fun schedule<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
    value: Option<V>,
    clock: &Clock,
): u64 {
    assert!(value != self.value(&entry), blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, 0, clock);
    let deadline = delayed::new_deadline(self.delay_ms, ready_at_ms);

    self.cancel_entry_if_pending(entry);
    self.pending.insert(entry, EntryProposal { value, deadline });

    sui::event::emit(MapScheduled {
        parent: self.parent,
        key: self.key,
        change: MapChange::Entry { entry, value },
        delay_ms: self.delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Applies `entry`'s ready change: sets its value or clears it.
public fun apply<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
    clock: &Clock,
) {
    assert!(self.pending.contains(&entry), blast_admin::errors::no_pending!());
    let EntryProposal { value, deadline } = self.pending[&entry];
    assert!(clock.timestamp_ms() >= deadline.ready_at_ms(), blast_admin::errors::not_ready!());

    self.pending.remove(&entry);
    if (self.entries.contains(entry)) {
        self.entries.remove(entry);
    };
    value.do!(|value| self.entries.add(entry, value));

    sui::event::emit(MapApplied {
        parent: self.parent,
        key: self.key,
        change: MapChange::Entry { entry, value },
        delay_ms: deadline.delay_ms(),
    });
}

/// Discards `entry`'s pending change, even a ready one.
public fun cancel<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
) {
    assert!(self.pending.contains(&entry), blast_admin::errors::no_pending!());
    self.cancel_entry_if_pending(entry);
}

/// Proposes only a new delay, ready after the applied one, and returns when. Pending
/// entry changes keep their deadlines.
public fun schedule_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_delay_if_pending();
    self.pending_delay.fill(delayed::new_pending_delay(delay_ms, ready_at_ms));

    sui::event::emit(MapScheduled<K, E, V> {
        parent: self.parent,
        key: self.key,
        change: MapChange::Delay,
        delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Applies the ready proposed delay to later entry changes.
public fun apply_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    clock: &Clock,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    let delay = self.pending_delay.extract();
    delayed::assert_ready_at(delay.ready_at_ms(), delay.delay_ms(), clock);

    self.delay_ms = delay.delay_ms();

    sui::event::emit(MapApplied<K, E, V> {
        parent: self.parent,
        key: self.key,
        change: MapChange::Delay,
        delay_ms: delay.delay_ms(),
    });
}

/// Discards the proposed delay, even a ready one.
public fun cancel_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    self.cancel_delay_if_pending();
}

/// Deletes a map with no pending entry or delay change and records its end, which also
/// ends every remaining entry.
public fun destroy<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: DelayedMap<K, E, V>,
) {
    assert!(
        self.pending.is_empty() && self.pending_delay.is_none(),
        blast_admin::errors::proposal_pending!(),
    );

    let DelayedMap { parent, key, entries, .. } = self;
    entries.drop();

    sui::event::emit(MapDestroyed<K, E, V> { parent, key });
}

/// The proposed value, or none when the change clears the entry.
public fun entry_proposal_value<V: copy + drop + store>(self: &EntryProposal<V>): Option<V> {
    self.value
}

/// The deadline the change waits.
public fun entry_proposal_deadline<V: copy + drop + store>(self: &EntryProposal<V>): Deadline {
    self.deadline
}

/// Whether `entry` has a pending change.
public fun is_pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
): bool {
    self.pending.contains(entry)
}

/// When `entry`'s pending change becomes ready, if one is pending.
public fun entry_ready_at_ms<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
): Option<u64> {
    self.pending.try_get(entry).map!(|proposal| proposal.deadline.ready_at_ms())
}

/// Whether `entry`'s pending change would apply now.
public fun is_ready<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
    clock: &Clock,
): bool {
    self.pending.try_get(entry).is_some_and!(|proposal| {
        clock.timestamp_ms() >= proposal.deadline.ready_at_ms()
    })
}

/// Whether a pending delay change would apply now.
public fun is_delay_ready<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    clock: &Clock,
): bool {
    self.pending_delay.is_some_and!(|delay| {
        delayed::is_ready_at(delay.ready_at_ms(), delay.delay_ms(), clock)
    })
}

/// The ID of the object that stores this map.
public fun parent<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): ID {
    self.parent
}

/// The module-defined key of this map.
public fun key<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): K {
    self.key
}

/// Whether `entry` has an applied value.
public fun contains<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
): bool {
    self.entries.contains(*entry)
}

/// How many entries have an applied value.
public fun length<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): u64 {
    self.entries.length()
}

/// How many entry changes are pending.
public fun pending_count<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): u64 {
    self.pending.length()
}

/// True when every change still to come waits a nonzero delay: the applied delay is nonzero,
/// no proposal would set it to zero, and no entry change scheduled earlier is pending.
public fun is_guarded<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): bool {
    self.delay_ms > 0
        && self.pending.is_empty()
        && self.pending_delay.is_none_or!(|delay| delay.delay_ms() > 0)
}

/// The entry a change touches, or none for a delay change.
public fun changed_entry<E: copy + drop + store, V: copy + drop + store>(
    self: &MapChange<E, V>,
): Option<E> {
    match (self) {
        MapChange::Entry { entry, value: _ } => option::some(*entry),
        MapChange::Delay => option::none(),
    }
}

/// The value an entry change proposes, whose inner none clears the entry, or none for a delay
/// change.
public fun changed_value<E: copy + drop + store, V: copy + drop + store>(
    self: &MapChange<E, V>,
): Option<Option<V>> {
    match (self) {
        MapChange::Entry { entry: _, value } => option::some(*value),
        MapChange::Delay => option::none(),
    }
}

// === Private Functions ===

fun cancel_entry_if_pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
) {
    if (!self.pending.contains(&entry)) return;
    let (_, EntryProposal { value, deadline }) = self.pending.remove(&entry);

    sui::event::emit(MapCancelled {
        parent: self.parent,
        key: self.key,
        change: MapChange::Entry { entry, value },
        delay_ms: deadline.delay_ms(),
        ready_at_ms: deadline.ready_at_ms(),
    });
}

fun cancel_delay_if_pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
) {
    if (self.pending_delay.is_none()) return;
    let delay = self.pending_delay.extract();

    sui::event::emit(MapCancelled<K, E, V> {
        parent: self.parent,
        key: self.key,
        change: MapChange::Delay,
        delay_ms: delay.delay_ms(),
        ready_at_ms: delay.ready_at_ms(),
    });
}

// === Test-Only Functions ===

#[test_only]
public fun map_created_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapCreated<K, E, V>,
): (ID, K, u64) {
    (self.parent, self.key, self.delay_ms)
}

#[test_only]
public fun map_scheduled_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapScheduled<K, E, V>,
): (ID, K, MapChange<E, V>, u64, u64) {
    (self.parent, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun map_cancelled_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapCancelled<K, E, V>,
): (ID, K, MapChange<E, V>, u64, u64) {
    (self.parent, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun map_applied_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapApplied<K, E, V>,
): (ID, K, MapChange<E, V>, u64) {
    (self.parent, self.key, self.change, self.delay_ms)
}

#[test_only]
public fun map_destroyed_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapDestroyed<K, E, V>,
): (ID, K) {
    (self.parent, self.key)
}

// === Events ===

/// A map was created empty with its first applied delay.
public struct MapCreated<
    K: copy + drop + store,
    phantom E: copy + drop + store,
    phantom V: copy + drop + store,
> has copy, drop {
    parent: ID,
    key: K,
    delay_ms: u64,
}

/// An entry change or delay change was proposed, ready from `ready_at_ms`. `delay_ms` is
/// the delay an entry change waits, or the proposed next delay.
public struct MapScheduled<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    parent: ID,
    key: K,
    change: MapChange<E, V>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed change was discarded, by cancellation or replacement; its fields match its
/// `MapScheduled`.
public struct MapCancelled<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    parent: ID,
    key: K,
    change: MapChange<E, V>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// An entry was set or cleared, or a delay change applied; `delay_ms` matches its
/// `MapScheduled`.
public struct MapApplied<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    parent: ID,
    key: K,
    change: MapChange<E, V>,
    delay_ms: u64,
}

/// A map was deleted with nothing pending, ending every remaining entry.
public struct MapDestroyed<
    K: copy + drop + store,
    phantom E: copy + drop + store,
    phantom V: copy + drop + store,
> has copy, drop {
    parent: ID,
    key: K,
}

// === Imports ===

public use fun entry_proposal_value as EntryProposal.value;
public use fun entry_proposal_deadline as EntryProposal.deadline;

use blast_admin::delayed::{Self, Deadline, PendingDelay};

use sui::{clock::Clock, table::{Self, Table}, vec_map::{Self, VecMap}};
