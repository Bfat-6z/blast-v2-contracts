// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed custody for the migrators package's Publisher and UpgradeCap.
///
/// Migrators shares the Launchpad's administration roles, so its governed
/// transitions take `AdminWitness<UpgradeAdmin>`, the role Launchpad declares.
/// Custody itself stays package-local: advancing Migrators leaves Launchpad on
/// its own generation.
module blast_fun_migrators::package_admin;

// === Public Types ===

/// The exact code digest or irreversible end of upgrades approved for execution.
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>),
    MakeImmutable,
    DelayOnly,
}

/// Shared custody for this package's framework Publisher and UpgradeCap.
public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN_MIGRATORS>,
    delay_ms: u64,
    pending: Option<Pending<UpgradeAction>>,
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

    assert!(digest.length() == 32, EInvalidDigest);

    let action = UpgradeAction::Upgrade(digest);
    let delay_ms = self.delay_ms;
    let pending = delayed::new_pending(action, delay_ms, delay_ms, clock);

    self.pending = option::some(pending);

    blast_events::upgrade_action_scheduled(option::some(digest), pending.ready_at_ms(), delay_ms);
}

/// Schedules the irreversible destruction of upgrade authority under the applied notice.
public fun schedule_make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    let action = UpgradeAction::MakeImmutable;
    let delay_ms = self.delay_ms;
    let pending = delayed::new_pending(action, delay_ms, delay_ms, clock);

    self.pending = option::some(pending);

    blast_events::upgrade_action_scheduled(option::none(), pending.ready_at_ms(), delay_ms);
}

/// Cancels any scheduled action, even after its execution threshold.
public fun cancel_upgrade_action(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    assert!(self.pending.is_some(), ENoPendingAction);

    let action = self.pending.extract().value();
    let digest = match (action) {
        UpgradeAction::Upgrade(digest) => option::some(digest),
        UpgradeAction::MakeImmutable => option::none(),
        UpgradeAction::DelayOnly => option::none()
    };

    blast_events::upgrade_action_cancelled(digest);
}

/// Consumes Publication forever, seals native capabilities, and enables Migrators.
public fun wrap(publication: Publication, upgrade_cap: UpgradeCap, ctx: &mut TxContext) {
    let (publisher, generation) = publication.destroy();
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN_MIGRATORS>(id.to_inner(), publisher, upgrade_cap);

    transfer::share_object(PackageAdmin { id, custody, delay_ms: 0, pending: option::none() });
    generation.share_version(ctx);
}

/// Authorizes the exact package digest under the sealed cap's compatible policy.
///
/// No path narrows that policy: every upgrade commits through `commit_upgrade_and_advance`,
/// whose new bytecode must compile the next generation constants.
public fun authorize_upgrade(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    digest: vector<u8>,
    clock: &Clock,
): UpgradeTicket {
    package_version.assert_current();

    let custodian_id = self.id.to_inner();

    assert!(self.pending.is_some(), ENoPendingAction);

    let (action, _) = self.pending.destroy_some().take_ready(clock);
    assert!(action == UpgradeAction::Upgrade(digest), EWrongUpgradeAction);
    self.pending = option::none();

    self.custody.authorize_upgrade(custodian_id, digest)
}

/// Commits the native receipt and advances one operational generation at once.
///
/// Every commit advances, so each upgrade must bump both constants in `package_version`: bytecode
/// that still compiles the old generation fails every generation check, `authorize_upgrade`
/// included, and would freeze the package.
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

/// Executes a ready immutability decision under the live upgrade role.
public fun make_immutable(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    _: &AdminWitness<UpgradeAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    assert!(self.pending.is_some(), ENoPendingAction);

    let (action, _) = self.pending.destroy_some().take_ready(clock);
    assert!(action == UpgradeAction::MakeImmutable, EWrongUpgradeAction);
    self.pending = option::none();

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

    let action = UpgradeAction::DelayOnly;
    let pending = delayed::new_pending(action, self.delay_ms, delay_ms, clock);

    self.pending = option::some(pending);

    blast_events::upgrade_delay_scheduled(delay_ms, pending.ready_at_ms());
}

/// Applies a ready policy-only proposal; cannot consume an upgrade authorization.
public fun apply_upgrade_delay(
    self: &mut PackageAdmin,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    assert!(self.pending.is_some(), ENoPendingAction);

    let (action, delay_ms) = self.pending.destroy_some().take_ready(clock);
    assert!(action == UpgradeAction::DelayOnly, EWrongUpgradeAction);
    self.pending = option::none();
    self.delay_ms = delay_ms;

    blast_events::upgrade_delay_changed(delay_ms);
}

/// Returns the currently applied notice period for upgrade actions.
public fun upgrade_delay_ms(self: &PackageAdmin): u64 {
    self.delay_ms
}

// === Test-Only Functions ===

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
/// Seals this package's test Publisher and a unit-test UpgradeCap, left unshared.
public fun new_for_testing(ctx: &mut TxContext): PackageAdmin {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<BLAST_FUN_MIGRATORS>(
        id.to_inner(),
        blast_fun_migrators::blast_fun_migrators::publisher_for_testing(ctx),
        sui::package::test_publish(
            std::type_name::original_id<BLAST_FUN_MIGRATORS>().to_id(),
            ctx,
        ),
    );

    PackageAdmin { id, custody, delay_ms: 172_800_000, pending: option::none() }
}

#[test_only]
public fun has_upgrade_cap_for_testing(self: &PackageAdmin): bool {
    self.custody.has_upgrade_cap()
}

// === Errors ===

#[error(code = 0)]
const EWrongUpgradeAction: vector<u8> = b"The ready action must match the requested upgrade digest or immutability.";
#[error(code = 1)]
const ENoPendingAction: vector<u8> = b"No upgrade action is scheduled.";
#[error(code = 2)]
const EInvalidDigest: vector<u8> = b"A package digest must contain 32 bytes.";

// === Imports ===

use blast_fun_migrators::{
    blast_events,
    blast_fun_migrators::{BLAST_FUN_MIGRATORS, Publication, PackageVersion},
};

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Pending},
    operational_version::OperationalVersion,
    upgrade_custody::{Self, UpgradeCustody},
};

use blast_fun::blast_fun_domain::{CancelAdmin, UpgradeAdmin};

use sui::{
    clock::Clock,
    package::{UpgradeCap, UpgradeReceipt, UpgradeTicket},
};

use fun blast_fun_migrators::blast_fun_migrators::share_version as OperationalVersion.share_version;
