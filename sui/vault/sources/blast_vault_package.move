// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the package module's abort location.
#[allow(lint(abort_without_constant))]
/// The vault package's publication, its venue admission, and its unpause.
///
/// Only an admitted venue may create a vault. A venue is admitted by its witness type, the one its
/// module alone can construct, so a vault's terms always come from the venue code that redeemed a
/// sale's migration or sealed its own standalone terms. An `AdapterAdmin` schedules an admission,
/// anyone applies it once its notice has passed, a `CancelAdmin` cancels it, and an
/// `AdapterAdmin` removes a venue at once.
///
/// The admission notice starts at zero and admissions ignore the pause, so Blast lists its venues
/// and raises the notice while publication keeps the package paused; `unpause` refuses until that
/// notice is guarded.
module blast_vault::blast_vault_package;

// === Public Types ===

/// The package's one-time witness and the marker of its version, publication, and roles.
public struct BLAST_VAULT_PACKAGE() has drop;

/// The witness `unpause` passes to clear pause bits; only this module constructs it.
public struct UnpauseWitness() has drop;

/// Keys the admitted venues' delayed lifecycle.
public struct VenuesKey() has copy, drop, store;

/// Shared singleton holding the venue witness types that may create vaults.
public struct VaultRegistry has key {
    id: UID,
    venues: DelayedSet<VenuesKey, TypeName>,
}

// === Private Initialization ===

fun init(otw: BLAST_VAULT_PACKAGE, ctx: &mut TxContext) {
    package_version::new_publication<_, UnpauseWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
    transfer::share_object(new_registry(ctx));
}

// === Public Functions ===

/// Schedules `Venue`'s admission after the applied notice. Framework and primitive types are
/// rejected because anyone can construct them.
public fun schedule_venue<Venue: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    let venue = type_name::with_original_ids<Venue>();
    assert!(!venue.is_primitive(), blast_vault::errors::invalid_venue!());
    let origin = type_name::original_id<Venue>();
    assert!(origin != @0x1 && origin != @0x2, blast_vault::errors::invalid_venue!());

    self.venues.schedule_add(venue, clock);
}

/// Applies `Venue`'s ready admission; anyone may call it.
public fun apply_venue<Venue: drop>(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.venues.apply_add(type_name::with_original_ids<Venue>(), clock);
}

/// Cancels `Venue`'s pending admission, even a ready one.
public fun cancel_venue<Venue: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.venues.cancel_add(type_name::with_original_ids<Venue>());
}

/// Removes an admitted venue at once; its existing vaults keep working.
public fun remove_venue<Venue: drop>(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.venues.remove(type_name::with_original_ids<Venue>());
}

/// Schedules a new admission notice after the applied one.
public fun schedule_venue_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<AdapterAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.venues.schedule_delay(delay_ms, clock);
}

/// Applies a ready admission-notice change; anyone may call it.
public fun apply_venue_delay(
    self: &mut VaultRegistry,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::generation!());

    self.venues.apply_delay(clock);
}

/// Cancels the pending admission-notice change, even a ready one.
public fun cancel_venue_delay(
    self: &mut VaultRegistry,
    _: &AdminWitness<CancelAdmin>,
    package_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
) {
    package_version.assert_current(constants::generation!());

    self.venues.cancel_delay();
}

/// Clears pause bits once the venue admission notice is guarded; the generic administration then
/// checks the upgrade notice and the pinned witness.
public fun unpause(
    self: &VaultRegistry,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>>,
    package_admin: &PackageAdmin<BLAST_VAULT_PACKAGE>,
    package_version: &mut PackageVersion<BLAST_VAULT_PACKAGE>,
    bits: u8,
) {
    assert!(self.venues.is_guarded(), blast_vault::errors::unguarded_notice!());

    package_admin.clear_pause_bits(unpause_admin, UnpauseWitness(), package_version, bits);
}

// === Package Functions ===

/// Aborts unless `Venue` is an admitted venue.
public(package) fun assert_admitted<Venue>(self: &VaultRegistry) {
    assert!(
        self.venues.contains(&type_name::with_original_ids<Venue>()),
        blast_vault::errors::unadmitted_venue!(),
    );
}

// === Private Functions ===

fun new_registry(ctx: &mut TxContext): VaultRegistry {
    let id = object::new(ctx);
    let venues = delayed_set::new(VenuesKey(), &id, constants::venue_admission_delay_ms!());

    VaultRegistry { id, venues }
}

// === Test-Only Functions ===

#[test_only]
/// An unshared registry with `Venue` already admitted at the launch notice of zero.
public fun registry_for_testing<Venue>(ctx: &mut TxContext): VaultRegistry {
    let mut registry = new_registry(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    let venue = type_name::with_original_ids<Venue>();
    registry.venues.schedule_add(venue, &clock);
    registry.venues.apply_add(venue, &clock);
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
    package_version::new_for_testing<_, UnpauseWitness>(constants::valid_pause_bits!(), ctx)
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
