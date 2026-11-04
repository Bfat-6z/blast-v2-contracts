// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// One package's sealed Publisher and UpgradeCap, its delayed upgrade decisions, and the
/// role-gated pause controls of its `PackageVersion`, typed by the package's one-time witness.
///
/// Each role is generic over the package marker, so the ACL stores `UpgradeAdmin<A>` and
/// `UpgradeAdmin<B>` as distinct grants and one package's administrator never reaches another's
/// custody. This package is immutable: no consumer bytecode generation gates these calls, and a
/// consumer whose new bytecode compiles the wrong generation can still schedule a repair.
module blast_admin::package_admin;

// === Constants ===

/// The notice every upgrade or immutability action waits from publication until changed.
const INITIAL_UPGRADE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Public Types ===

/// The exact code digest or irreversible end of upgrades approved for execution.
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>),
    MakeImmutable,
}

/// Keys the delayed lifecycle of one package's upgrade actions and their notice.
public struct UpgradeKey<phantom PackageMarker: drop>() has copy, drop, store;

/// Shared custody for one package's framework Publisher and UpgradeCap.
public struct PackageAdmin<phantom PackageMarker: drop> has key {
    id: UID,
    custody: UpgradeCustody<PackageMarker>,
    upgrade: DelayedAction<UpgradeKey<PackageMarker>, UpgradeAction>,
}

/// Schedules and executes the package's upgrades and immutability, and changes their notice.
public struct UpgradeAdmin<phantom PackageMarker>()

/// May set the package's pause bits immediately, never clear them.
public struct PauseAdmin<phantom PackageMarker>()

/// May clear the package's pause bits, only through the package's own unpause.
public struct UnpauseAdmin<phantom PackageMarker>()

/// May cancel the package's scheduled upgrade action or notice change.
public struct CancelAdmin<phantom PackageMarker>()

// === Public Functions ===

/// Consumes the unique publication proof, seals the native capabilities and shares both the
/// administration and the package version. The version starts with every defined bit paused;
/// an `UnpauseAdmin` releases it through the package's own unpause.
public fun wrap<PackageMarker: drop>(
    publication: Publication<PackageMarker>,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
) {
    let (publisher, package_version) = publication.into_version(ctx);
    let id = object::new(ctx);
    let custody = upgrade_custody::new<PackageMarker>(id.to_inner(), publisher, upgrade_cap);
    let upgrade = delayed_action::new(UpgradeKey<PackageMarker>(), &id, INITIAL_UPGRADE_DELAY_MS);

    transfer::share_object(PackageAdmin { id, custody, upgrade });
    package_version.share();
}

/// Schedules one exact code digest under the applied notice, replacing any previous action.
/// Changing the notice requires a separate notice-only proposal. Aborts once the package is
/// immutable.
public fun schedule_upgrade<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    digest: vector<u8>,
    clock: &Clock,
) {
    assert!(self.custody.has_upgrade_cap(), blast_admin::errors::upgrade_cap_unavailable!());
    assert!(
        digest.length() == upgrade_custody::package_digest_length(),
        blast_admin::errors::invalid_package_digest!(),
    );

    self.upgrade.schedule(UpgradeAction::Upgrade(digest), clock);
}

/// Schedules the irreversible destruction of upgrade authority under the applied notice.
/// Aborts once the package is immutable.
public fun schedule_make_immutable<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    clock: &Clock,
) {
    assert!(self.custody.has_upgrade_cap(), blast_admin::errors::upgrade_cap_unavailable!());

    self.upgrade.schedule(UpgradeAction::MakeImmutable, clock);
}

/// Cancels the scheduled action or notice change, even after its execution threshold.
public fun cancel_upgrade_action<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<CancelAdmin<PackageMarker>>,
) {
    self.upgrade.cancel();
}

/// Consumes the ready upgrade action for exactly `digest` and authorizes it under the sealed
/// cap's current policy.
public fun authorize_upgrade<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    digest: vector<u8>,
    clock: &Clock,
): UpgradeTicket {
    let action = self.upgrade.take_action(clock);
    assert!(
        action == UpgradeAction::Upgrade(digest),
        blast_admin::errors::wrong_upgrade_action!(),
    );

    self.custody.authorize_upgrade(self.id.to_inner(), digest)
}

/// Commits the native receipt into the sealed cap and advances the package version by one
/// generation, together. The new bytecode must compile that generation; bytecode compiling any
/// other fails every `assert_current`, while these calls stay available to schedule a repair.
public fun commit_upgrade_and_advance<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    package_version: &mut PackageVersion<PackageMarker>,
    receipt: UpgradeReceipt,
) {
    // Computed first so a generation overflow aborts before the receipt is committed or emitted.
    let next_generation = package_version.next_generation();

    self.custody.commit_upgrade(self.id.to_inner(), receipt);
    package_version.advance(next_generation);
}

/// Consumes the ready immutability action and irreversibly destroys native upgrade authority.
public fun make_immutable<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    clock: &Clock,
) {
    let action = self.upgrade.take_action(clock);
    assert!(action == UpgradeAction::MakeImmutable, blast_admin::errors::wrong_upgrade_action!());

    self.custody.make_immutable(self.id.to_inner());
}

/// Proposes only a new upgrade notice, ready after the applied one; replaces any pending
/// upgrade or immutability action.
public fun schedule_upgrade_delay<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    delay_ms: u64,
    clock: &Clock,
) {
    self.upgrade.schedule_delay(delay_ms, clock);
}

/// Applies a ready notice-only proposal; anyone may call it, and it cannot consume an action.
public fun apply_upgrade_delay<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    clock: &Clock,
) {
    self.upgrade.apply_delay(clock);
}

/// Sets the requested pause bits immediately.
public fun pause<PackageMarker: drop>(
    package_version: &mut PackageVersion<PackageMarker>,
    _: &AdminWitness<PauseAdmin<PackageMarker>>,
    bits: u8,
) {
    package_version.set_pause_bits(bits);
}

/// Clears the requested pause bits for the package's own unpause, which first checks its own
/// configuration notices and then passes a value of the exact witness type the package pinned
/// at publication. Aborts while any upgrade notice still to come could be zero. Only the
/// package's unpause constructs that type, so a role alone cannot skip its checks.
public fun clear_pause_bits<PackageMarker: drop, UnpauseWitness: drop>(
    self: &PackageAdmin<PackageMarker>,
    _: &AdminWitness<UnpauseAdmin<PackageMarker>>,
    _: UnpauseWitness,
    package_version: &mut PackageVersion<PackageMarker>,
    bits: u8,
) {
    package_version.assert_unpause_witness<_, UnpauseWitness>();
    assert!(self.upgrade.is_guarded(), blast_admin::errors::unguarded_upgrade_notice!());

    package_version.clear_pause_bits(bits);
}

// === Test-Only Functions ===

#[test_only]
/// Seals a consumer's test Publisher and unit-test UpgradeCap, left unshared.
public fun new_for_testing<PackageMarker: drop>(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin<PackageMarker> {
    let id = object::new(ctx);
    let custody = upgrade_custody::new<PackageMarker>(id.to_inner(), publisher, upgrade_cap);
    let upgrade = delayed_action::new(UpgradeKey<PackageMarker>(), &id, INITIAL_UPGRADE_DELAY_MS);

    PackageAdmin { id, custody, upgrade }
}

#[test_only]
/// Exercises both upgrade phases with a synthetic 48-hour advance.
public fun authorize_upgrade_for_testing<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    admin: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    digest: vector<u8>,
    ctx: &mut TxContext,
): UpgradeTicket {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_upgrade(admin, digest, &clock);
    clock.set_for_testing(INITIAL_UPGRADE_DELAY_MS);
    let ticket = self.authorize_upgrade(admin, digest, &clock);
    clock.destroy_for_testing();

    ticket
}

#[test_only]
public fun make_immutable_for_testing<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    admin: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_make_immutable(admin, &clock);
    clock.set_for_testing(INITIAL_UPGRADE_DELAY_MS);
    self.make_immutable(admin, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun initial_upgrade_delay_ms_for_testing(): u64 {
    INITIAL_UPGRADE_DELAY_MS
}

#[test_only]
public fun upgrade_for_testing<PackageMarker: drop>(
    self: &PackageAdmin<PackageMarker>,
): &DelayedAction<UpgradeKey<PackageMarker>, UpgradeAction> {
    &self.upgrade
}

#[test_only]
public fun custody_for_testing<PackageMarker: drop>(
    self: &PackageAdmin<PackageMarker>,
): &UpgradeCustody<PackageMarker> {
    &self.custody
}

#[test_only]
public fun id_for_testing<PackageMarker: drop>(self: &PackageAdmin<PackageMarker>): ID {
    self.id.to_inner()
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_action::{Self, DelayedAction},
    package_version::{PackageVersion, Publication},
    upgrade_custody::{Self, UpgradeCustody}
};

use sui::{clock::Clock, package::{Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket}};
