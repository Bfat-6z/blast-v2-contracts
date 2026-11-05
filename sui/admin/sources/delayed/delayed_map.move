// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Keyed values under one shared notice, such as per-coin overrides. Every entry change,
/// setting or clearing, waits the notice applied when it was scheduled, and its deadline is
/// fixed then; a later notice change never moves it. See `delayed` for the shared rules.
module blast_admin::delayed_map;

// === Public Types ===

/// Applied values by entry, one applied notice, at most one pending change per entry, and at
/// most one proposed notice. Values live in a Table, so reads cost one entry and the map
/// grows without bound; pending changes are few and live inline.
public struct DelayedMap<
    K: copy + drop + store,
    E: copy + drop + store,
    V: copy + drop + store,
> has store {
    owner: ID,
    key: K,
    entries: Table<E, V>,
    delay_ms: u64,
    pending: VecMap<E, EntryProposal<V>>,
    pending_delay: Option<Notice>,
}

/// A proposed entry value, or none to clear the entry, and the notice it waits.
public struct EntryProposal<V: copy + drop + store> has copy, drop, store {
    value: Option<V>,
    notice: Notice,
}

/// What a map proposal does once applied.
public enum MapChange<E: copy + drop + store, V: copy + drop + store> has copy, drop, store {
    /// Sets the entry to `value`, or clears it when `value` is none.
    Entry { entry: E, value: Option<V> },
    /// Changes the notice for later entry changes.
    Delay,
}

// === Public Functions ===

/// An empty map; every entry change waits the applied notice.
public fun new<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    key: K,
    owner: &UID,
    delay_ms: u64,
    ctx: &mut TxContext,
): DelayedMap<K, E, V> {
    delayed::assert_delay(delay_ms);
    let owner = owner.to_inner();

    sui::event::emit(MapCreated<K, E, V> { owner, key, delay_ms });

    DelayedMap {
        owner,
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

/// The applied notice for entry changes, in milliseconds.
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

/// The proposed next notice, if any.
public fun pending_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): Option<Notice> {
    self.pending_delay
}

/// Proposes setting `entry` to `value` (none clears it) after the applied notice, and
/// returns when. A replaced change is cancelled and the full notice restarts. Aborts when
/// `value` is already the applied value.
public fun schedule<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
    value: Option<V>,
    clock: &Clock,
): u64 {
    assert!(value != self.value(&entry), blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, 0, clock);
    let notice = delayed::new_notice(self.delay_ms, ready_at_ms);

    self.cancel_entry_if_pending(entry);
    self.pending.insert(entry, EntryProposal { value, notice });

    sui::event::emit(MapScheduled {
        owner: self.owner,
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
    let EntryProposal { value, notice } = self.pending[&entry];
    assert!(clock.timestamp_ms() >= notice.ready_at_ms(), blast_admin::errors::not_ready!());

    self.pending.remove(&entry);
    if (self.entries.contains(entry)) {
        self.entries.remove(entry);
    };
    value.do!(|value| self.entries.add(entry, value));

    sui::event::emit(MapApplied {
        owner: self.owner,
        key: self.key,
        change: MapChange::Entry { entry, value },
        delay_ms: notice.delay_ms(),
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

/// Proposes only a new notice, ready after the applied one, and returns when. Pending
/// entry changes keep their deadlines.
public fun schedule_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    delay_ms: u64,
    clock: &Clock,
): u64 {
    assert!(delay_ms != self.delay_ms, blast_admin::errors::unchanged!());
    let ready_at_ms = delayed::ready_at_ms_after(self.delay_ms, delay_ms, clock);

    self.cancel_delay_if_pending();
    self.pending_delay.fill(delayed::new_notice(delay_ms, ready_at_ms));

    sui::event::emit(MapScheduled<K, E, V> {
        owner: self.owner,
        key: self.key,
        change: MapChange::Delay,
        delay_ms,
        ready_at_ms,
    });

    ready_at_ms
}

/// Applies the ready proposed notice to later entry changes.
public fun apply_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    clock: &Clock,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    let notice = self.pending_delay.extract();
    delayed::assert_ready_at(notice.ready_at_ms(), notice.delay_ms(), clock);

    self.delay_ms = notice.delay_ms();

    sui::event::emit(MapApplied<K, E, V> {
        owner: self.owner,
        key: self.key,
        change: MapChange::Delay,
        delay_ms: notice.delay_ms(),
    });
}

/// Discards the proposed notice, even a ready one.
public fun cancel_delay<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
) {
    assert!(self.pending_delay.is_some(), blast_admin::errors::no_pending!());
    self.cancel_delay_if_pending();
}

/// Deletes a map with no pending entry or notice change and records its end, which also
/// ends every remaining entry.
public fun destroy<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: DelayedMap<K, E, V>,
) {
    assert!(
        self.pending.is_empty() && self.pending_delay.is_none(),
        blast_admin::errors::proposal_pending!(),
    );

    let DelayedMap { owner, key, entries, .. } = self;
    entries.drop();

    sui::event::emit(MapDestroyed<K, E, V> { owner, key });
}

/// The proposed value, or none when the change clears the entry.
public fun entry_proposal_value<V: copy + drop + store>(self: &EntryProposal<V>): Option<V> {
    self.value
}

/// The notice the change waits and when it becomes ready.
public fun entry_proposal_notice<V: copy + drop + store>(self: &EntryProposal<V>): Notice {
    self.notice
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
    self.pending.try_get(entry).map!(|proposal| proposal.notice.notice_ready_at_ms())
}

/// Whether `entry`'s pending change would apply now.
public fun is_ready<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    entry: &E,
    clock: &Clock,
): bool {
    self.pending.try_get(entry).is_some_and!(|proposal| {
        clock.timestamp_ms() >= proposal.notice.notice_ready_at_ms()
    })
}

/// Whether a pending notice change would apply now.
public fun is_delay_ready<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
    clock: &Clock,
): bool {
    self.pending_delay.is_some_and!(|notice| {
        delayed::is_ready_at(notice.notice_ready_at_ms(), notice.notice_delay_ms(), clock)
    })
}

/// The ID of the object that stores this map.
public fun owner<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): ID {
    self.owner
}

/// The owner-defined key of this map.
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
public fun entry_count<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
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

/// True when every change still to come waits a nonzero notice: the applied notice is nonzero,
/// no proposal would set it to zero, and no entry change scheduled earlier is pending.
public fun is_guarded<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &DelayedMap<K, E, V>,
): bool {
    self.delay_ms > 0
        && self.pending.is_empty()
        && self.pending_delay.is_none_or!(|notice| notice.notice_delay_ms() > 0)
}

/// The entry a change touches, or none for a notice change.
public fun changed_entry<E: copy + drop + store, V: copy + drop + store>(
    self: &MapChange<E, V>,
): Option<E> {
    match (self) {
        MapChange::Entry { entry, value: _ } => option::some(*entry),
        MapChange::Delay => option::none(),
    }
}

/// The value an entry change proposes (none clears), or none for a notice change.
public fun changed_value<E: copy + drop + store, V: copy + drop + store>(
    self: &MapChange<E, V>,
): Option<V> {
    match (self) {
        MapChange::Entry { entry: _, value } => *value,
        MapChange::Delay => option::none(),
    }
}

// === Private Functions ===

fun cancel_entry_if_pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
    entry: E,
) {
    if (!self.pending.contains(&entry)) return;
    let (_, EntryProposal { value, notice }) = self.pending.remove(&entry);

    sui::event::emit(MapCancelled {
        owner: self.owner,
        key: self.key,
        change: MapChange::Entry { entry, value },
        delay_ms: notice.delay_ms(),
        ready_at_ms: notice.ready_at_ms(),
    });
}

fun cancel_delay_if_pending<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &mut DelayedMap<K, E, V>,
) {
    if (self.pending_delay.is_none()) return;
    let notice = self.pending_delay.extract();

    sui::event::emit(MapCancelled<K, E, V> {
        owner: self.owner,
        key: self.key,
        change: MapChange::Delay,
        delay_ms: notice.delay_ms(),
        ready_at_ms: notice.ready_at_ms(),
    });
}

// === Test-Only Functions ===

#[test_only]
public fun map_created_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapCreated<K, E, V>,
): (ID, K, u64) {
    (self.owner, self.key, self.delay_ms)
}

#[test_only]
public fun map_scheduled_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapScheduled<K, E, V>,
): (ID, K, MapChange<E, V>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun map_cancelled_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapCancelled<K, E, V>,
): (ID, K, MapChange<E, V>, u64, u64) {
    (self.owner, self.key, self.change, self.delay_ms, self.ready_at_ms)
}

#[test_only]
public fun map_applied_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapApplied<K, E, V>,
): (ID, K, MapChange<E, V>, u64) {
    (self.owner, self.key, self.change, self.delay_ms)
}

#[test_only]
public fun map_destroyed_fields<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store>(
    self: &MapDestroyed<K, E, V>,
): (ID, K) {
    (self.owner, self.key)
}

// === Events ===

/// A map was created empty with its first applied notice.
public struct MapCreated<
    K: copy + drop + store,
    phantom E: copy + drop + store,
    phantom V: copy + drop + store,
> has copy, drop {
    owner: ID,
    key: K,
    delay_ms: u64,
}

/// An entry change or notice change was proposed, ready from `ready_at_ms`. `delay_ms` is
/// the notice an entry change waits, or the proposed next notice.
public struct MapScheduled<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: MapChange<E, V>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// A proposed change was discarded, by cancellation or replacement; its fields match its
/// `MapScheduled`.
public struct MapCancelled<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    owner: ID,
    key: K,
    change: MapChange<E, V>,
    delay_ms: u64,
    ready_at_ms: u64,
}

/// An entry was set or cleared, or a notice change applied; `delay_ms` matches its
/// `MapScheduled`.
public struct MapApplied<K: copy + drop + store, E: copy + drop + store, V: copy + drop + store> has copy, drop {
    owner: ID,
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
    owner: ID,
    key: K,
}

// === Imports ===

public use fun entry_proposal_value as EntryProposal.value;
public use fun entry_proposal_notice as EntryProposal.notice;

use blast_admin::delayed::{Self, Notice};

use sui::{clock::Clock, table::{Self, Table}, vec_map::{Self, VecMap}};
