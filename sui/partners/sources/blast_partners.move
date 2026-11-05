// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the partner's abort location.
#[allow(lint(abort_without_constant))]
/// Blast partner codes, shared by every Blast product.
///
/// A partner is one deal: it is paid a share of the fee Blast charges on every
/// trade that names it, in the same transaction. A company holds one
/// `PartnerCap` for all its deals, each a separate partner with its own share.
/// Blast's partner administrator registers partners under a cap, proposes each
/// one's share, and can propose moving a partner to another cap; the cap's holder
/// sets where each of its partners is paid. Initial terms apply at registration.
/// A later share or cap applies only when someone applies it, no sooner than
/// `PARTNER_CHANGE_DELAY_MS` after it was proposed. That notice is fixed: this
/// module never changes it, and the package is published immutable. The
/// recipient the cap holder sets applies at once.
///
/// Products call `pay` with Blast's own fee on a trade. `pay` emits
/// `PartnerPaid` for what the partner received; the product records the trade
/// and the amount in its own event. Share and cap lifecycle events come from
/// `blast_admin::delayed`, keyed by `ShareKey` and `CapKey` and owned by the partner.
module blast_partners::blast_partners;

// === Public Types ===

/// The one administrator role in the shared Blast ACL: register partners, and
/// propose or cancel shares and moves between caps.
public struct PartnerAdmin()

/// One Blast partner. Shared, and read by immutable reference on every trade that names it. It has
/// no destroy: launches, presales, and vaults bind its ID for good and pay Blast's held fees only
/// with it, so deleting it would strand those fees. A zero share switches it off instead.
public struct Partner has key {
    id: UID,
    /// Where the partner's share is sent; set by the live cap's holder.
    recipient: address,
    /// The partner's share of Blast's fee on each trade, in basis points.
    share_bps: Delayed<ShareKey, u64>,
    /// The only cap that may set `recipient`; one cap may manage many partners.
    cap_id: Delayed<CapKey, ID>,
}

/// Keys a partner share's delayed lifecycle.
public struct ShareKey() has copy, drop, store;

/// Keys a partner managing cap's delayed lifecycle.
public struct CapKey() has copy, drop, store;

/// A company's authority over the recipient of every partner bound to it.
public struct PartnerCap has key, store {
    id: UID,
}

// === Public Functions ===

/// Mints a cap. It controls nothing until Blast registers a partner under it,
/// so anyone may mint one, a company included.
public fun new_cap(ctx: &mut TxContext): PartnerCap {
    PartnerCap { id: object::new(ctx) }
}

/// Registers and shares a partner managed by the cap `cap_id`, with its share
/// and managing cap in force immediately.
public fun register(
    _: &AdminWitness<PartnerAdmin>,
    cap_id: ID,
    recipient: address,
    share_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(recipient != @0x0, blast_partners::errors::invalid_recipient!());
    assert!(share_bps <= MAX_SHARE_BPS, blast_partners::errors::share_above_max!());

    let partner = new(recipient, share_bps, cap_id, ctx);

    partner.emit_updated();

    transfer::share_object(partner);
}

/// Proposes `share_bps` as the partner's share, applicable by anyone after the fixed
/// notice. A different proposal replaces a pending one and restarts the full notice;
/// `cancel_share` discards one, even after its notice has elapsed. Proposing the
/// applied or the pending share aborts.
public fun schedule_share(
    self: &mut Partner,
    _: &AdminWitness<PartnerAdmin>,
    share_bps: u64,
    clock: &Clock,
) {
    assert!(share_bps <= MAX_SHARE_BPS, blast_partners::errors::share_above_max!());
    assert!(
        !self.share_bps.pending().is_some_and!(|proposal| proposal.value() == share_bps),
        blast_partners::errors::unchanged!(),
    );

    self.share_bps.schedule_value(share_bps, clock);
}

/// Applies the proposed share once its notice has elapsed. Anyone may call, the partner included.
public fun apply_share(self: &mut Partner, clock: &Clock) {
    self.share_bps.apply(clock);
}

/// Discards the proposed share, even a ready one, keeping the applied share.
public fun cancel_share(self: &mut Partner, _: &AdminWitness<PartnerAdmin>) {
    self.share_bps.cancel();
}

/// Proposes the cap `cap_id` to manage the partner, to replace a lost or stolen
/// cap, applicable by anyone after the fixed notice. The applied cap keeps working
/// until then. A different proposal replaces a pending one and restarts the full
/// notice; `cancel_cap` discards one, even after its notice has elapsed. Proposing
/// the applied or the pending cap aborts.
public fun schedule_cap(
    self: &mut Partner,
    _: &AdminWitness<PartnerAdmin>,
    cap_id: ID,
    clock: &Clock,
) {
    assert!(
        !self.cap_id.pending().is_some_and!(|proposal| proposal.value() == cap_id),
        blast_partners::errors::unchanged!(),
    );

    self.cap_id.schedule_value(cap_id, clock);
}

/// Applies the proposed managing cap once its notice has elapsed. Anyone may call.
public fun apply_cap(self: &mut Partner, clock: &Clock) {
    self.cap_id.apply(clock);
}

/// Discards the proposed managing cap, even a ready one, keeping the applied cap.
public fun cancel_cap(self: &mut Partner, _: &AdminWitness<PartnerAdmin>) {
    self.cap_id.cancel();
}

/// Sets where the partner is paid, at once. Only the applied cap may.
public fun set_recipient(self: &mut Partner, cap: &PartnerCap, recipient: address) {
    assert!(cap.id.to_inner() == self.cap_id.value(), blast_partners::errors::not_live_cap!());
    assert!(recipient != @0x0, blast_partners::errors::invalid_recipient!());
    assert!(recipient != self.recipient, blast_partners::errors::unchanged!());

    self.recipient = recipient;

    self.emit_updated();
}

/// Destroys a cap, live or not.
public fun destroy_cap(cap: PartnerCap) {
    let PartnerCap { id } = cap;
    id.delete();
}

/// Transfers the partner its applied share of `fee` (Blast's fee on one trade) as a
/// coin, rounded down so Blast keeps the remainder, emits `PartnerPaid`, and returns
/// the amount sent. Nothing is sent or emitted while the share is zero. `fee`
/// keeps the rest. Anyone calling it pays the partner from their own balance.
public fun pay<T>(self: &Partner, fee: &mut Balance<T>, ctx: &mut TxContext): u64 {
    let amount = fee.value().mul_div(self.share_bps.value(), BASIS_POINTS);

    if (amount > 0) {
        transfer::public_transfer(fee.split(amount).into_coin(ctx), self.recipient);
        event::emit(PartnerPaid<T> { partner_id: self.id.to_inner(), amount });
    };

    amount
}

/// The fixed notice every change Blast makes to a partner waits. Products use it
/// for their own notice, such as how long a partner they remove stays accepted.
public fun delay_ms(): u64 {
    PARTNER_CHANGE_DELAY_MS
}

/// The largest share of Blast's fee one partner may earn, in basis points: 8,000.
public fun max_share_bps(): u64 {
    MAX_SHARE_BPS
}

/// Where the partner's share is sent now.
public fun recipient(self: &Partner): address {
    self.recipient
}

/// The applied share of Blast's fee, in basis points; `pay` uses it.
public fun share_bps(self: &Partner): u64 {
    self.share_bps.value()
}

/// The proposed share with its ready time, if any. It changes nothing until applied.
public fun pending_share_bps(self: &Partner): Option<Proposal<u64>> {
    self.share_bps.pending()
}

/// Whether `apply_share` would succeed now: a share is proposed, its ready time has passed, and
/// the fixed notice still fits in a Unix millisecond timestamp.
public fun is_share_ready(self: &Partner, clock: &Clock): bool {
    self.share_bps.is_ready(clock)
}

/// The ID of the applied cap, the only one that may set the recipient.
public fun cap_id(self: &Partner): ID {
    self.cap_id.value()
}

/// The proposed managing cap's ID with its ready time, if any. It changes nothing until applied.
public fun pending_cap_id(self: &Partner): Option<Proposal<ID>> {
    self.cap_id.pending()
}

/// Whether `apply_cap` would succeed now: a cap is proposed, its ready time has passed, and the
/// fixed notice still fits in a Unix millisecond timestamp.
public fun is_cap_ready(self: &Partner, clock: &Clock): bool {
    self.cap_id.is_ready(clock)
}

// === Private Functions ===

/// A partner with `share_bps` and `cap_id` applied at once and the fixed notice.
fun new(recipient: address, share_bps: u64, cap_id: ID, ctx: &mut TxContext): Partner {
    let id = object::new(ctx);

    Partner {
        recipient,
        share_bps: delayed::new(ShareKey(), &id, share_bps, PARTNER_CHANGE_DELAY_MS),
        cap_id: delayed::new(CapKey(), &id, cap_id, PARTNER_CHANGE_DELAY_MS),
        id,
    }
}

fun emit_updated(self: &Partner) {
    event::emit(PartnerUpdated { partner_id: self.id.to_inner(), recipient: self.recipient });
}

// === Test-Only Functions ===

#[test_only]
/// A partner whose share is already in force, for products' own tests.
public fun new_for_testing(recipient: address, share_bps: u64, ctx: &mut TxContext): Partner {
    new(recipient, share_bps, object::id_from_address(@0x0), ctx)
}

#[test_only]
/// A partner whose applied share is `before`, with `after` proposed at `clock` and
/// ready after the fixed notice, for products' own tests.
public fun new_scheduled_for_testing(
    recipient: address,
    before: u64,
    after: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Partner {
    let mut partner = new_for_testing(recipient, before, ctx);
    partner.share_bps.schedule_value(after, clock);
    partner
}

#[test_only]
public fun partner_paid_fields<T>(self: &PartnerPaid<T>): (ID, u64) {
    (self.partner_id, self.amount)
}

#[test_only]
public fun partner_updated_fields(self: &PartnerUpdated): (ID, address) {
    (self.partner_id, self.recipient)
}

// === Events ===

/// Emitted at registration and on every recipient change: the partner's recipient.
/// Its share and cap events are `blast_admin::delayed`'s, owned by `partner_id`.
public struct PartnerUpdated has copy, drop {
    partner_id: ID,
    recipient: address,
}

/// Emitted whenever a partner is paid: `amount` of `T` sent to its recipient.
public struct PartnerPaid<phantom T> has copy, drop {
    partner_id: ID,
    amount: u64,
}

// === Constants ===

/// The fixed notice before a share or a cap Blast proposes can apply, and how long a partner a
/// `partner_list::PartnerList` removes stays accepted.
const PARTNER_CHANGE_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// The largest share of Blast's fee one partner may earn: 80%.
const MAX_SHARE_BPS: u64 = 8_000;

/// Basis points in one whole.
const BASIS_POINTS: u64 = 10_000;

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, delayed::{Self, Delayed, Proposal}};

use sui::{balance::Balance, clock::Clock, event};
