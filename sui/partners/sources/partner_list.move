// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the list's abort location.
#[allow(lint(abort_without_constant))]
/// The partners one Blast product accepts, one list per product.
///
/// A product embeds a `PartnerList` in the object holding its policy and alone decides who may
/// change it: the list has `store` and no authority of its own, so only the embedding module can
/// reach it mutably. Adding a partner accepts it at once. Removing one keeps it accepted for the
/// fixed notice Blast gives for every change to a partner, `blast_partners::delay_ms()`, so
/// anything built to name it keeps working that long. Sales and trades that already name a
/// removed partner keep paying it; the list only gates naming it anew. Destroying the list ends
/// every acceptance at once, without the notice, so a product destroys it only with the object
/// that embeds it.
module blast_partners::partner_list;

// === Public Types ===

/// The partners one product accepts: each partner's ID maps to the time, in Unix epoch
/// milliseconds, it stops being accepted, `u64::MAX` until the product removes it. `owner` is the
/// object that embeds the list, named by its events.
public struct PartnerList has store {
    owner: ID,
    acceptance_ends_at_ms: Table<ID, u64>,
}

// === Public Functions ===

/// An empty list embedded in `owner`.
public fun new(owner: &UID, ctx: &mut TxContext): PartnerList {
    PartnerList { owner: owner.to_inner(), acceptance_ends_at_ms: table::new(ctx) }
}

/// Accepts `partner` at once. Adding a partner whose removal is pending cancels the removal;
/// adding a removed partner accepts it again. Aborts when it is already accepted with no removal
/// pending.
public fun add(self: &mut PartnerList, partner: &Partner) {
    let partner_id = object::id(partner);

    if (self.acceptance_ends_at_ms.contains(partner_id)) {
        let acceptance_ends_at_ms = &mut self.acceptance_ends_at_ms[partner_id];
        assert!(
            *acceptance_ends_at_ms != std::u64::max_value!(),
            blast_partners::errors::unchanged!(),
        );
        *acceptance_ends_at_ms = std::u64::max_value!();
    } else {
        self.acceptance_ends_at_ms.add(partner_id, std::u64::max_value!());
    };

    event::emit(PartnerAdded { owner: self.owner, partner_id });
}

/// Stops accepting `partner_id` once the fixed notice, `blast_partners::delay_ms()`, has passed
/// from now. Aborts unless the partner is accepted now with no removal pending.
public fun remove(self: &mut PartnerList, partner_id: ID, clock: &Clock) {
    let now_at_ms = clock.timestamp_ms();
    self.assert_accepted_at(partner_id, now_at_ms);
    let stored_ends_at_ms = &mut self.acceptance_ends_at_ms[partner_id];
    assert!(*stored_ends_at_ms == std::u64::max_value!(), blast_partners::errors::unchanged!());

    let acceptance_ends_at_ms = now_at_ms + partners::delay_ms();
    *stored_ends_at_ms = acceptance_ends_at_ms;

    event::emit(PartnerRemoved { owner: self.owner, partner_id, acceptance_ends_at_ms });
}

/// Aborts unless the list accepts `partner_id` now: it was added, and any removal's notice has
/// not yet passed.
public fun assert_accepted(self: &PartnerList, partner_id: ID, clock: &Clock) {
    self.assert_accepted_at(partner_id, clock.timestamp_ms());
}

/// Deletes the list and every entry, accepted or removed, and emits `PartnerListDestroyed`. The
/// embedding module alone holds the list by value, so it alone decides when its acceptance ends.
public fun destroy(self: PartnerList) {
    let PartnerList { owner, acceptance_ends_at_ms } = self;

    acceptance_ends_at_ms.drop();

    event::emit(PartnerListDestroyed { owner });
}

/// Whether the list accepts `partner_id` now; `assert_accepted` aborts exactly when this is false.
public fun is_accepted(self: &PartnerList, partner_id: ID, clock: &Clock): bool {
    self.is_accepted_at(partner_id, clock.timestamp_ms())
}

/// Whether the list has an entry for `partner_id`: accepted, removal pending, or removed.
public fun contains(self: &PartnerList, partner_id: ID): bool {
    self.acceptance_ends_at_ms.contains(partner_id)
}

/// When the list stops accepting `partner_id`, in Unix epoch milliseconds and exclusive:
/// `u64::MAX` until removed. Aborts in `sui::dynamic_field` unless the list `contains` it.
public fun acceptance_ends_at_ms(self: &PartnerList, partner_id: ID): u64 {
    self.acceptance_ends_at_ms[partner_id]
}

/// The number of entries, removed partners included.
public fun length(self: &PartnerList): u64 {
    self.acceptance_ends_at_ms.length()
}

/// The object that embeds the list, named by its events.
public fun owner(self: &PartnerList): ID {
    self.owner
}

// === Private Functions ===

/// Aborts unless the list accepts `partner_id` at `now_at_ms`.
fun assert_accepted_at(self: &PartnerList, partner_id: ID, now_at_ms: u64) {
    assert!(
        self.is_accepted_at(partner_id, now_at_ms),
        blast_partners::errors::partner_not_accepted!(),
    );
}

/// Whether the list accepts `partner_id` at `now_at_ms`.
fun is_accepted_at(self: &PartnerList, partner_id: ID, now_at_ms: u64): bool {
    self.acceptance_ends_at_ms.contains(partner_id)
        && now_at_ms < self.acceptance_ends_at_ms[partner_id]
}

// === Test-Only Functions ===

#[test_only]
public fun partner_added_fields(self: &PartnerAdded): (ID, ID) {
    (self.owner, self.partner_id)
}

#[test_only]
public fun partner_removed_fields(self: &PartnerRemoved): (ID, ID, u64) {
    (self.owner, self.partner_id, self.acceptance_ends_at_ms)
}

#[test_only]
public fun partner_list_destroyed_fields(self: &PartnerListDestroyed): ID {
    self.owner
}

// === Events ===

/// The owner's list accepts the partner from now on.
public struct PartnerAdded has copy, drop {
    owner: ID,
    partner_id: ID,
}

/// The owner's list accepts the partner until `acceptance_ends_at_ms` (Unix epoch milliseconds),
/// exclusive.
public struct PartnerRemoved has copy, drop {
    owner: ID,
    partner_id: ID,
    acceptance_ends_at_ms: u64,
}

/// The owner's list was deleted: it accepts no partner from now on.
public struct PartnerListDestroyed has copy, drop {
    owner: ID,
}

// === Imports ===

use blast_partners::blast_partners::{Self as partners, Partner};

use sui::{clock::Clock, event, table::{Self, Table}};
