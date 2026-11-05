// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the package module's abort location.
#[allow(lint(abort_without_constant))]
/// The vault package's publication, its witness admission, and its unpause.
///
/// One list of admitted witness types decides who may create a vault: the venue whose witness
/// calls `vault::new`, and the issuer whose witness sealed the vault's terms, must both be on it.
/// Each witness is the one its module alone can construct. The launchpad and presale witnesses
/// are issuers; a venue is a venue and, for the standalone vaults whose terms it seals itself, an
/// issuer too. The list does not distinguish the two roles, so an admitted product witness would
/// also pass the venue check; both are Blast-reviewed code, and products never call `vault::new`.
/// Gating venues binds every position key to venue code Blast reviewed; gating issuers keeps a
/// stranger's terms, with a Blast share and partner of its choosing, out of Blast vaults.
///
/// An admitted venue obtains `VaultTerms` only from `migration::redeem` or by sealing them itself
/// under its own witness from Blast policy; it never accepts `VaultTerms` from its caller. Terms
/// are `copy`, so a venue that took them as an argument would let anyone who obtained a sale's
/// terms create a second vault claiming that sale.
///
/// An `AdapterAdmin` schedules an admission, anyone applies it once its notice has passed, a
/// `CancelAdmin` cancels it, and an `AdapterAdmin` removes a witness at once. Removing a venue
/// stops it creating vaults; removing an issuer stops every vault for its sales, so a migration
/// sealed by it can no longer complete. Existing vaults keep working either way.
///
/// The admission notice starts at zero and admissions ignore the pause, so Blast lists the
/// launchpad, presale, and venue witnesses and raises the notice while publication keeps the
/// package paused; `unpause` refuses until that notice is guarded. The product and venue packages
/// must therefore be published before the vault is unpaused.
module blast_vault::blast_vault_package;

// === Public Types ===

/// The package's one-time witness and the marker of its version, publication, and roles.
public struct BLAST_VAULT_PACKAGE() has drop;

/// The package witness `blast_admin` pins at publication: `unpause` passes it to clear pause bits.
/// Only this module constructs it, and it is never stored or returned.
public struct PackageWitness() has drop;

/// Keys the admitted witnesses' delayed lifecycle.
public struct WitnessesKey() has copy, drop, store;

/// Shared singleton holding the venue and issuer witness types that may create vaults.
public struct VaultRegistry has key {
    id: UID,
    witnesses: DelayedSet<WitnessesKey, TypeName>,
}

// === Private Initialization ===

fun init(otw: BLAST_VAULT_PACKAGE, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
    transfer::share_object(new_registry(ctx));
}

// === Public Functions ===

/// Schedules `Witness`'s admission after the applied notice. Framework and primitive types are
/// rejected because anyone can construct them.
public fun schedule_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    let witness = type_name::with_original_ids<Witness>();
    assert!(!witness.is_primitive(), blast_vault::errors::invalid_witness!());
    let origin = type_name::original_id<Witness>();
    assert!(origin != @0x1 && origin != @0x2, blast_vault::errors::invalid_witness!());

    self.witnesses.schedule_add(witness, clock);
}

/// Applies `Witness`'s ready admission; anyone may call it.
public fun apply_witness<Witness: drop>(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.apply_add(type_name::with_original_ids<Witness>(), clock);
}

/// Cancels `Witness`'s pending admission, even a ready one.
public fun cancel_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.cancel_add(type_name::with_original_ids<Witness>());
}

/// Removes an admitted witness at once; existing vaults keep working.
public fun remove_witness<Witness: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.remove(type_name::with_original_ids<Witness>());
}

/// Schedules a new admission notice after the applied one.
public fun schedule_witness_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.schedule_delay(delay_ms, clock);
}

/// Applies a ready admission-notice change; anyone may call it.
public fun apply_witness_delay(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.apply_delay(clock);
}

/// Cancels the pending admission-notice change, even a ready one.
public fun cancel_witness_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.witnesses.cancel_delay();
}

/// Clears pause bits once the witness admission notice is guarded; the generic administration
/// then checks the upgrade notice and the pinned witness.
public fun unpause(
    self: &VaultRegistry,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>>,
    package_admin: &PackageAdmin<BLAST_VAULT_PACKAGE>,
    package_version: &mut PackageVersion<BLAST_VAULT_PACKAGE>,
    bits: u8,
) {
    assert!(self.witnesses.is_guarded(), blast_vault::errors::unguarded_notice!());

    package_admin.clear_pause_bits(unpause_admin, PackageWitness(), package_version, bits);
}

// === Package Functions ===

/// Aborts unless `Venue` is an admitted witness.
public(package) fun assert_venue<Venue>(self: &VaultRegistry) {
    assert!(
        self.witnesses.contains(&type_name::with_original_ids<Venue>()),
        blast_vault::errors::unadmitted_venue!(),
    );
}

/// Aborts unless `issuer`, a terms' sealing witness in its original-ID form, is admitted.
public(package) fun assert_issuer(self: &VaultRegistry, issuer: TypeName) {
    assert!(self.witnesses.contains(&issuer), blast_vault::errors::unadmitted_issuer!());
}

/// The registry's UID, from which `vault::new` derives each vault's ID; nothing else in the
/// package writes it.
public(package) fun uid_mut(self: &mut VaultRegistry): &mut UID {
    &mut self.id
}

// === Private Functions ===

fun new_registry(ctx: &mut TxContext): VaultRegistry {
    let id = object::new(ctx);
    let witnesses = delayed_set::new(
        WitnessesKey(),
        &id,
        constants::witness_admission_delay_ms!(),
    );

    VaultRegistry { id, witnesses }
}

// === Test-Only Functions ===

#[test_only]
/// An unshared registry with `Venue` and `Issuer` already admitted at the launch notice of zero.
public fun registry_for_testing<Venue, Issuer>(ctx: &mut TxContext): VaultRegistry {
    let mut registry = new_registry(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    let venue = type_name::with_original_ids<Venue>();
    registry.witnesses.schedule_add(venue, &clock);
    registry.witnesses.apply_add(venue, &clock);
    let issuer = type_name::with_original_ids<Issuer>();
    registry.witnesses.schedule_add(issuer, &clock);
    registry.witnesses.apply_add(issuer, &clock);
    clock.destroy_for_testing();

    registry
}

#[test_only]
/// An unshared registry as publication creates it: nothing admitted, at zero notice.
public fun empty_registry_for_testing(ctx: &mut TxContext): VaultRegistry {
    new_registry(ctx)
}

#[test_only]
/// An unshared, unpaused version for tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_VAULT_PACKAGE> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_set::{Self, DelayedSet},
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::{Self, PackageVersion}
};

use blast_core::blast_domain::{AdapterAdmin, CancelAdmin};

use blast_vault::constants;

use std::type_name::{Self, TypeName};

use sui::clock::Clock;
