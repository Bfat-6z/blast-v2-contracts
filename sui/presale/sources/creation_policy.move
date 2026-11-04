// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's allowlists for new presales: the Quote coins a sale may raise, the venues, in this
/// package or another, whose tickets may start a sale, and the Blast partners a sale may name.
///
/// A presale is checked once, when it is created. Later changes apply only to later sales, so a
/// delisting never strands a live sale's commitments, blocks its migration, or stops paying its
/// partner.
module blast_presale::creation_policy;

// === Public Types ===

/// Shared singleton holding the Quote types and venues new presales may use.
public struct CreationPolicy has key {
    id: UID,
    allowed_quotes: VecSet<TypeName>,
    venues: DelayedSet<VenueKey, TypeName>,
}

/// Keys the delayed lifecycle of venue admissions and their notice.
public struct VenueKey() has copy, drop, store;

/// Dynamic-field key of a Blast partner new presales may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(0, ctx));
}

// === Public Functions ===

/// Allows or disallows `Quote` for presales created afterward; existing ones keep it.
public fun set_quote_allowed<Quote>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current();

    let quote = type_name::with_original_ids<Quote>();
    assert!(
        self.allowed_quotes.contains(&quote) != allowed,
        blast_presale::errors::allowance_unchanged!(),
    );

    if (allowed) self.allowed_quotes.insert(quote) else self.allowed_quotes.remove(&quote);

    event::emit(QuoteSet { quote, allowed });
}

/// Admits a venue's witness type after the applied admission notice. An admitted venue's tickets
/// start presales afterward, and only that venue redeems their migrations; existing sales keep
/// their venue. Rescheduling a pending admission restarts its notice.
///
/// `presale::new` and `presale::migrate` are public, so whoever can construct an admitted witness
/// can open sales and redeem their liquidity. Admit only a struct whose defining module is the
/// reviewed venue and keeps its constructor private. A primitive, a vector, or a framework type,
/// any of which a caller can construct, is rejected.
public fun schedule_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    clock: &Clock,
) {
    package_version.assert_current();

    let venue = type_name::with_original_ids<Venue>();
    assert!(!venue.is_primitive(), blast_presale::errors::invalid_venue!());
    let origin = type_name::original_id<Venue>();
    assert!(origin != @0x1 && origin != @0x2, blast_presale::errors::invalid_venue!());

    self.venues.schedule_add(venue, clock);
}

/// Permissionlessly applies the approved admission once ready.
public fun apply_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.venues.apply_add(type_name::with_original_ids<Venue>(), clock);
}

/// Cancels a pending venue admission, including after its threshold.
public fun cancel_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.venues.cancel_add(type_name::with_original_ids<Venue>());
}

/// Immediately removes a venue for new presales and cancels any pending admission.
public fun remove_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
) {
    package_version.assert_current();

    self.venues.remove(type_name::with_original_ids<Venue>());
}

/// Lets new presales name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let key = PartnerKey(partner_id);

    if (self.id.has_dynamic_field(key)) {
        let acceptance_ends_at_ms: &mut u64 = self.id.dynamic_field_mut(key);
        assert!(
            *acceptance_ends_at_ms != std::u64::max_value!(),
            blast_presale::errors::allowance_unchanged!(),
        );
        *acceptance_ends_at_ms = std::u64::max_value!();
    } else {
        self.id.add_dynamic_field(key, std::u64::max_value!());
    };

    event::emit(PartnerAdded { partner_id });
}

/// Stops new presales naming `partner` after the notice Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Sales that already name it keep paying it.
public fun remove_partner(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let now_at_ms = clock.timestamp_ms();
    self.assert_partner(partner_id, now_at_ms);
    let notice_ends_at_ms = now_at_ms + partners::delay_ms();

    let acceptance_ends_at_ms: &mut u64 = self.id.dynamic_field_mut(PartnerKey(partner_id));
    assert!(
        *acceptance_ends_at_ms == std::u64::max_value!(),
        blast_presale::errors::allowance_unchanged!(),
    );
    *acceptance_ends_at_ms = notice_ends_at_ms;

    event::emit(PartnerRemoved { partner_id, accepted_until_ms: notice_ends_at_ms });
}

/// Proposes only the admission notice. Existing admission deadlines remain fixed.
public fun schedule_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    self.venues.schedule_delay(delay_ms, clock);
}

/// Permissionlessly applies a ready admission-notice proposal.
public fun apply_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.venues.apply_delay(clock);
}

/// Cancels only the admission-notice proposal.
public fun cancel_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.venues.cancel_delay();
}

// === Package Functions ===

/// True when the venue allowlist's notice is guarded (see `package_admin::unpause`).
public(package) fun is_guarded(self: &CreationPolicy): bool {
    self.venues.is_guarded()
}

/// Aborts unless a new presale may raise `Quote` and migrate to `venue`.
public(package) fun assert_allowed<Quote>(self: &CreationPolicy, venue: TypeName) {
    assert!(
        self.allowed_quotes.contains(&type_name::with_original_ids<Quote>()),
        blast_presale::errors::quote_not_allowed!(),
    );
    assert!(self.venues.contains(&venue), blast_presale::errors::venue_not_allowed!());
}

/// Aborts unless a new presale may name the partner `partner_id` at `now_at_ms`.
public(package) fun assert_partner(self: &CreationPolicy, partner_id: ID, now_at_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.has_dynamic_field(key), blast_presale::errors::partner_not_accepted!());

    let acceptance_ends_at_ms: u64 = *self.id.dynamic_field(key);
    assert!(now_at_ms < acceptance_ends_at_ms, blast_presale::errors::partner_not_accepted!());
}

// === Private Functions ===

fun new(delay_ms: u64, ctx: &mut TxContext): CreationPolicy {
    let id = object::new(ctx);
    let venues = delayed_set::new(VenueKey(), &id, delay_ms);

    CreationPolicy { id, allowed_quotes: vec_set::empty(), venues }
}

// === Test-Only Functions ===

#[test_only]
/// Reads the shared admission policy independently of pending admissions.
public fun venue_delay_ms_for_testing(self: &CreationPolicy): u64 {
    self.venues.delay_ms()
}

#[test_only]
public fun venues_for_testing(self: &CreationPolicy): &DelayedSet<VenueKey, TypeName> {
    &self.venues
}

#[test_only]
public fun set_venue_allowed_for_testing<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    admin: &AdminWitness<AdapterAdmin>,
    allowed: bool,
    ctx: &mut TxContext,
) {
    if (!allowed) {
        self.remove_venue<Venue>(package_version, admin);
        return
    };
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_venue<Venue>(package_version, admin, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_venue<Venue>(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): CreationPolicy {
    new(172_800_000, ctx)
}

#[test_only]
/// The allowlist exactly as publication creates it, at zero notice.
public fun new_publication_for_testing(ctx: &mut TxContext): CreationPolicy {
    new(0, ctx)
}

/// A policy that allows exactly `Quote` and `Venue`, admitted at zero notice before the 48-hour
/// notice applies.
#[test_only]
public fun allowing_for_testing<Quote, Venue>(ctx: &mut TxContext): CreationPolicy {
    let clock = sui::clock::create_for_testing(ctx);
    let mut policy = new(0, ctx);
    let venue = type_name::with_original_ids<Venue>();
    policy.allowed_quotes.insert(type_name::with_original_ids<Quote>());
    policy.venues.schedule_add(venue, &clock);
    policy.venues.apply_add(venue, &clock);
    policy.venues.schedule_delay(172_800_000, &clock);
    policy.venues.apply_delay(&clock);
    clock.destroy_for_testing();

    policy
}

#[test_only]
public fun destroy_for_testing(self: CreationPolicy) {
    let CreationPolicy { id, allowed_quotes: _, venues } = self;
    std::unit_test::destroy(venues);
    id.delete();
}

#[test_only]
public fun quote_set_fields(event: &QuoteSet): (TypeName, bool) {
    (event.quote, event.allowed)
}

#[test_only]
public fun partner_added_fields(event: &PartnerAdded): ID {
    event.partner_id
}

#[test_only]
public fun partner_removed_fields(event: &PartnerRemoved): (ID, u64) {
    (event.partner_id, event.accepted_until_ms)
}

// === Events ===

/// Presales created afterward may (`allowed`) or may not raise `quote`.
public struct QuoteSet has copy, drop {
    quote: TypeName,
    allowed: bool,
}

/// Presales created from now on may name the partner `partner_id`.
public struct PartnerAdded has copy, drop {
    partner_id: ID,
}

/// Presales created before `accepted_until_ms` may still name the partner `partner_id`; later ones
/// may not.
public struct PartnerRemoved has copy, drop {
    partner_id: ID,
    accepted_until_ms: u64,
}

// === Imports ===

use sui::{clock::Clock, dynamic_field, event, vec_set::{Self, VecSet}};

use blast_admin::{
    delayed_set::{Self, DelayedSet},
    blast_acl::AdminWitness,
};

use blast_partners::blast_partners::{Self as partners, Partner};

use blast_presale::{
    blast_presale_domain::{AdapterAdmin, CancelAdmin, FeeAdmin, ListingAdmin},
    blast_presale_package::{PackageVersion}
};

use std::type_name::{Self, TypeName};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow as UID.dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
