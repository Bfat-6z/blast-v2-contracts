// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the admin's abort location.
#[allow(lint(abort_without_constant))]
/// Shared custody of this package's Publisher and UpgradeCap, driven by package administrators.
module blast_fun::package_admin;

// === Public Types ===

/// A proposed upgrade or irreversible immutability.
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>),
    MakeImmutable,
}

/// Keys the upgrade custody's delayed lifecycle.
public struct UpgradeKey() has copy, drop, store;

/// Shared custody for the package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN>,
    upgrade: DelayedAction<UpgradeKey, UpgradeAction>,
}

// === Public Functions ===

/// Schedules one exact code digest under the applied notice, replacing any previous action.
/// Changing the notice requires a separate policy-only proposal.
public fun schedule_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock
) {
    package_version.assert_current();

    assert!(digest.length() == 32, blast_fun::errors::invalid_digest!());

    self.upgrade.schedule(UpgradeAction::Upgrade(digest), clock);
}

/// Schedules the irreversible destruction of upgrade authority under the applied notice.
public fun schedule_make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    self.upgrade.schedule(UpgradeAction::MakeImmutable, clock);
}

/// Cancels any scheduled action or notice change, even after its execution threshold.
public fun cancel_upgrade_action(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.upgrade.cancel();
}

/// Consumes the unique publication proof and seals native custody before activation.
/// The initial operational generation starts fully paused; UnpauseAdmin releases it immediately.
public fun wrap(publication: Publication, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let (publisher, generation) = publication.destroy();
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN>(id.to_inner(), publisher, upgrade_cap);
    let upgrade = delayed::new_action(UpgradeKey(), id.to_inner(), 0);

    transfer::share_object(PackageAdmin { id, custody, upgrade });
    generation.share_version(ctx);
}

/// Authorizes the exact package digest under the wrapped cap's current policy.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
): UpgradeTicket {
    package_version.assert_current();

    let custodian_id = self.id.to_inner();

    let action = self.upgrade.take_action(clock);
    assert!(action == UpgradeAction::Upgrade(digest), blast_fun::errors::wrong_upgrade_action!());

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the upgrade and advances the package version together.
public fun commit_upgrade_and_advance(
    self: &mut PackageAdmin,
    package_version: &mut PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    receipt: UpgradeReceipt,
) {
    package_version.assert_next();

    let custodian_id = self.id.to_inner();

    self.custody.commit_upgrade(custodian_id, receipt);
    package_version.advance();
}

/// Irreversibly destroys native upgrade authority and freezes this package generation.

/// Executes a ready immutability decision under the live upgrade role.
public fun make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    let action = self.upgrade.take_action(clock);
    assert!(action == UpgradeAction::MakeImmutable, blast_fun::errors::wrong_upgrade_action!());

    self.custody.make_immutable(self.id.to_inner());
}

/// Changes only the upgrade notice period, after the currently applied notice.
/// Replaces any pending upgrade or immutability action.
public fun schedule_upgrade_delay(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current();

    self.upgrade.schedule_delay(delay_ms, clock);
}

/// Applies a ready policy-only proposal; cannot consume an upgrade authorization.
public fun apply_upgrade_delay(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.upgrade.apply_delay(clock);
}

// === Test-Only Functions ===

#[test_only]
/// Returns the currently applied notice period for upgrade actions.
public fun upgrade_delay_ms(self: &PackageAdmin): u64 {
    self.upgrade.delay_ms()
}

#[test_only]
public fun upgrade_for_testing(self: &PackageAdmin): &DelayedAction<UpgradeKey, UpgradeAction> {
    &self.upgrade
}

#[test_only]
/// Fixture helper exercising both public phases with a synthetic 48-hour advance.
public fun authorize_upgrade_for_testing(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    ctx: &mut TxContext,
): UpgradeTicket {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_upgrade(package_version, admin, digest, &clock);
    clock.set_for_testing(172_800_000);
    let ticket = self.authorize_upgrade(package_version, admin, digest, &clock);
    clock.destroy_for_testing();

    ticket
}

#[test_only]
public fun make_immutable_for_testing(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    admin: &AdminWitness<UpgradeAdmin>,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_make_immutable(package_version, admin, &clock);
    clock.set_for_testing(172_800_000);
    self.make_immutable(package_version, admin, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Creates unshared package administration around simulated package capabilities.
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN>(
        id.to_inner(),
        blast_fun::blast_fun::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_FUN>().to_id(),
            ctx,
        ),
    );

    let upgrade = delayed::new_action(UpgradeKey(), id.to_inner(), 172_800_000);

    PackageAdmin { id, custody, upgrade }
}

#[test_only]
public fun id_for_testing(self: &PackageAdmin): ID {
    self.id.to_inner()
}

#[test_only]
public fun publisher_id_for_testing(self: &PackageAdmin): ID {
    self.custody.publisher_id_for_testing()
}

#[test_only]
public fun upgrade_cap_id_for_testing(self: &PackageAdmin): ID {
    self.custody.upgrade_cap_id_for_testing()
}

#[test_only]
public fun package_id_for_testing(self: &PackageAdmin): ID {
    self.custody.current_package_id_for_testing()
}

#[test_only]
public fun version_for_testing(self: &PackageAdmin): u64 {
    self.custody.native_version_for_testing()
}

#[test_only]
public fun policy_for_testing(self: &PackageAdmin): u8 {
    self.custody.policy_for_testing()
}

#[test_only]
/// Reports whether native upgrade authority remains sealed in this package's custody.
public fun has_upgrade_cap_for_testing(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, DelayedAction},
    operational_version::OperationalVersion,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_fun::{
    blast_fun::{BLAST_FUN, Publication, PackageVersion},
    blast_fun_domain::{CancelAdmin, UpgradeAdmin},
};

use sui::{
    clock::Clock,
    package::{UpgradeCap, UpgradeReceipt, UpgradeTicket},
};

use fun blast_fun::blast_fun::share_version as OperationalVersion.share_version;
