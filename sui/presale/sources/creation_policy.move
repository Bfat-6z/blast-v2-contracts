// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's allowlists for new presales and new vaults without a presale: the Quote coins a sale may
/// raise or a vault may hold, the migrators, in this package or another, that may create a sale or,
/// for this package's venues, such a vault, and the Blast partners a sale may name.
///
/// A presale or vault is checked once, when it is created. Later changes apply only to later sales, so a
/// delisting never strands a live sale's commitments, blocks its migration, or stops paying its
/// partner.
module blast_presale::creation_policy;

// === Public Types ===

/// Shared singleton holding the Quote types and migration witnesses new presales may use.
public struct CreationPolicy has key {
    id: UID,
    allowed_quotes: VecSet<TypeName>,
    migration_witnesses: DelayedSet<MigrationWitnessKey, TypeName>,
}

/// Keys the delayed lifecycle of migration-witness admissions and their notice.
public struct MigrationWitnessKey() has copy, drop, store;

/// Dynamic-field key of a Blast partner new presales may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(0, ctx));
}

// === Public Functions ===

/// Allows or disallows `Quote` for presales and vaults without a presale created afterward;
/// existing ones keep it.
public fun set_quote_allowed<Quote>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current();

    let quote = type_name::with_original_ids<Quote>();
    assert!(self.allowed_quotes.contains(&quote) != allowed, EAllowanceUnchanged);

    if (allowed) self.allowed_quotes.insert(quote) else self.allowed_quotes.remove(&quote);

    event::emit(QuoteSet { quote, allowed });
}

/// Allows or disallows the migrator identified by `MigrationWitness` to create presales, and its
/// venue vaults without a presale, afterward; existing sales still migrate through it.
///
/// `presale::new` and `presale::migrate` are public, so whoever can construct an allowed witness
/// can open sales and release their liquidity. Allow only a struct whose defining module is the
/// reviewed migrator and keeps its constructor private. A primitive, a vector, or a framework type,
/// any of which a caller can construct, is rejected.
/// Admits an adapter only after the currently applied admission notice.
public fun schedule_migration_witness<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    let witness = type_name::with_original_ids<MigrationWitness>();
    assert!(!witness.is_primitive(), EInvalidMigrationWitness);

    let origin = type_name::original_id<MigrationWitness>();
    assert!(origin != @0x1 && origin != @0x2, EInvalidMigrationWitness);

    self.migration_witnesses.schedule_add(witness, clock);
}

/// Permissionlessly applies the approved admission once ready.
public fun apply_migration_witness<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.apply_add(type_name::with_original_ids<MigrationWitness>(), clock);
}

/// Cancels a pending adapter admission, including after its threshold.
public fun cancel_migration_witness<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.cancel_add(type_name::with_original_ids<MigrationWitness>());
}

/// Immediately removes adapter authority and cancels any pending admission.
public fun remove_migration_witness<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.remove(type_name::with_original_ids<MigrationWitness>());
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
        assert!(*acceptance_ends_at_ms != std::u64::max_value!(), EAllowanceUnchanged);
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
    assert!(*acceptance_ends_at_ms == std::u64::max_value!(), EAllowanceUnchanged);
    *acceptance_ends_at_ms = notice_ends_at_ms;

    event::emit(PartnerRemoved { partner_id, accepted_until_ms: notice_ends_at_ms });
}

/// Proposes only the admission notice period. Existing admission deadlines remain fixed.
public fun schedule_migration_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.schedule_delay(delay_ms, clock);
}

/// Permissionlessly applies a ready admission-policy proposal.
public fun apply_migration_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.apply_delay(clock);
}

/// Cancels only the admission-policy proposal.
public fun cancel_migration_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.cancel_delay();
}

// === Package Functions ===

/// Aborts unless a new presale, or a new vault without a presale, may use `Quote` and be created
/// by `MigrationWitness`'s migrator.
public(package) fun assert_allowed<Quote, MigrationWitness>(self: &CreationPolicy) {
    assert!(self.allowed_quotes.contains(&type_name::with_original_ids<Quote>()), EQuoteNotAllowed);
    assert!(
        self.migration_witnesses.contains(&type_name::with_original_ids<MigrationWitness>()),
        EMigrationWitnessNotAllowed,
    );
}

/// Aborts unless a new presale may name the partner `partner_id` at `now_at_ms`.
public(package) fun assert_partner(self: &CreationPolicy, partner_id: ID, now_at_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.has_dynamic_field(key), EPartnerNotAccepted);

    let acceptance_ends_at_ms: u64 = *self.id.dynamic_field(key);
    assert!(now_at_ms < acceptance_ends_at_ms, EPartnerNotAccepted);
}

// === Private Functions ===

fun new(delay_ms: u64, ctx: &mut TxContext): CreationPolicy {
    let id = object::new(ctx);
    let migration_witnesses = delayed::new_set(MigrationWitnessKey(), &id, delay_ms);

    CreationPolicy { id, allowed_quotes: vec_set::empty(), migration_witnesses }
}

// === Test-Only Functions ===

#[test_only]
/// Reads the shared admission policy independently of pending admissions.
public fun migration_delay_ms_for_testing(self: &CreationPolicy): u64 {
    self.migration_witnesses.delay_ms()
}

#[test_only]
public fun migration_witnesses_for_testing(
    self: &CreationPolicy,
): &DelayedSet<MigrationWitnessKey, TypeName> {
    &self.migration_witnesses
}

#[test_only]
public fun set_migration_witness_allowed_for_testing<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion,
    admin: &AdminWitness<AdapterAdmin>,
    allowed: bool,
    ctx: &mut TxContext
) {
    if (!allowed) {
        self.remove_migration_witness<MigrationWitness>(package_version, admin);
        return
    };
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_migration_witness<MigrationWitness>(package_version, admin, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_migration_witness<MigrationWitness>(package_version, &clock);
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

/// A policy that allows exactly `Quote` and `MigrationWitness`, admitted at zero notice before the
/// 48-hour notice applies.
#[test_only]
public fun allowing_for_testing<Quote, MigrationWitness>(ctx: &mut TxContext): CreationPolicy {
    let clock = sui::clock::create_for_testing(ctx);
    let mut policy = new(0, ctx);
    let witness = type_name::with_original_ids<MigrationWitness>();
    policy.allowed_quotes.insert(type_name::with_original_ids<Quote>());
    policy.migration_witnesses.schedule_add(witness, &clock);
    policy.migration_witnesses.apply_add(witness, &clock);
    policy.migration_witnesses.schedule_delay(172_800_000, &clock);
    policy.migration_witnesses.apply_delay(&clock);
    clock.destroy_for_testing();

    policy
}

#[test_only]
public fun destroy_for_testing(self: CreationPolicy) {
    let CreationPolicy { id, allowed_quotes: _, migration_witnesses } = self;
    std::unit_test::destroy(migration_witnesses);
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

// === Errors ===

#[error(code = 0)]
const EAllowanceUnchanged: vector<u8> = b"An allowlist update must change whether the type or partner is allowed.";

#[error(code = 1)]
const EQuoteNotAllowed: vector<u8> = b"This Quote type is not allowed for new presales.";

#[error(code = 2)]
const EMigrationWitnessNotAllowed: vector<u8> = b"This migration witness is not allowed for new presales.";

#[error(code = 3)]
const EInvalidMigrationWitness: vector<u8> = b"A migration witness must be a non-framework struct, never a primitive, vector, or framework type any caller can construct.";

#[error(code = 4)]
const EPartnerNotAccepted: vector<u8> = b"New presales may not name this partner.";

// === Imports ===

use sui::{clock::Clock, dynamic_field, event, vec_set::{Self, VecSet}};

use blast_admin::{
    delayed::{Self, DelayedSet},
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
