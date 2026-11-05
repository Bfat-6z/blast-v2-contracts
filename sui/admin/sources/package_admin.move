// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// One package's sealed Publisher and UpgradeCap, its delayed upgrade decisions, and the
/// role-gated pause controls of its `PackageVersion`, typed by the package's one-time witness.
///
/// The native capabilities never leave the shared `PackageAdmin`: only the package itself, with
/// its package witness, borrows the Publisher by immutable reference, nothing lends the
/// UpgradeCap, and the cap acts only through a scheduled upgrade or the one terminal
/// `make_immutable`. Each role is generic over the package marker, so the ACL stores
/// `UpgradeAdmin<A>` and `UpgradeAdmin<B>` as distinct grants and one package's administrator
/// never reaches another's custody. This package is immutable: no consumer bytecode generation
/// gates these calls, and a consumer whose new bytecode compiles the wrong generation can still
/// schedule a repair.
module blast_admin::package_admin;

// === Constants ===

/// The notice every upgrade or immutability action waits from publication until changed.
const INITIAL_UPGRADE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

/// The byte length of a package digest, the only length `schedule_upgrade` accepts.
const PACKAGE_DIGEST_LENGTH: u64 = 32;

/// The framework stamps a freshly published package's `UpgradeCap` with version one.
const INITIAL_NATIVE_VERSION: u64 = 1;

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
    publisher: Publisher,
    /// Native upgrade authority; `none` once the package is immutable.
    upgrade_cap: Option<UpgradeCap>,
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

/// Consumes the unique publication proof, seals the never-upgraded native cap of the marker's
/// package beside its Publisher, and shares both the administration and the package version.
/// The version starts with every defined bit paused; an `UnpauseAdmin` releases it through the
/// package's own unpause.
public fun wrap<PackageMarker: drop>(
    publication: Publication<PackageMarker>,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
) {
    assert!(
        upgrade_cap.package().to_address() == type_name::original_id<PackageMarker>()
            && upgrade_cap.version() == INITIAL_NATIVE_VERSION,
        blast_admin::errors::invalid_upgrade_cap!(),
    );

    let (publisher, package_version) = publication.into_version(ctx);

    transfer::share_object(new<PackageMarker>(publisher, upgrade_cap, ctx));
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
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());
    assert!(
        digest.length() == PACKAGE_DIGEST_LENGTH,
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
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

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
/// cap's current policy. A scheduled upgrade implies the cap: scheduling requires it, and only a
/// consumed immutability action removes it.
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

    let custodian_id = self.id.to_inner();
    let upgrade_cap = self.upgrade_cap.borrow_mut();
    let upgrade_cap_id = object::id(upgrade_cap);
    let package_id = upgrade_cap.package();
    let native_version = upgrade_cap.version();
    let policy = upgrade_cap.policy();

    let ticket = upgrade_cap.authorize(policy, digest);

    blast_admin_events::upgrade_authorized<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
        *ticket.digest(),
    );

    ticket
}

/// Commits the native receipt into the sealed cap that authorized it, then advances the package
/// version by one generation in the same call. The new bytecode must compile that generation; bytecode
/// compiling any other fails every `assert_current`, while these calls stay available to schedule
/// a repair.
public fun commit_upgrade_and_advance<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    package_version: &mut PackageVersion<PackageMarker>,
    receipt: UpgradeReceipt,
) {
    assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());

    let custodian_id = self.id.to_inner();
    let upgrade_cap = self.upgrade_cap.borrow_mut();
    let upgrade_cap_id = object::id(upgrade_cap);
    let previous_native_version = upgrade_cap.version();
    let new_package_id = receipt.package();

    upgrade_cap.commit(receipt);

    blast_admin_events::upgrade_committed<PackageMarker>(
        custodian_id,
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        new_package_id,
        previous_native_version,
        upgrade_cap.version(),
    );

    package_version.advance();
}

/// Consumes the ready immutability action and irreversibly destroys native upgrade authority;
/// the Publisher stays sealed. This is the one terminal upgrade action: the cap's policy is
/// never narrowed in between.
public fun make_immutable<PackageMarker: drop>(
    self: &mut PackageAdmin<PackageMarker>,
    _: &AdminWitness<UpgradeAdmin<PackageMarker>>,
    clock: &Clock,
) {
    let action = self.upgrade.take_action(clock);
    assert!(action == UpgradeAction::MakeImmutable, blast_admin::errors::wrong_upgrade_action!());

    let upgrade_cap = self.upgrade_cap.extract();
    let upgrade_cap_id = object::id(&upgrade_cap);
    let final_native_version = upgrade_cap.version();
    let final_policy = upgrade_cap.policy();

    package::make_immutable(upgrade_cap);

    blast_admin_events::upgrade_cap_destroyed<PackageMarker>(
        self.id.to_inner(),
        upgrade_cap_id,
        type_name::original_id<PackageMarker>(),
        final_native_version,
        final_policy,
    );
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
/// configuration notices and then passes a value of its package witness, the type pinned at
/// publication. Aborts while any upgrade notice still to come could be zero. Only the package's
/// own code constructs that type, so a role alone cannot skip its checks.
public fun clear_pause_bits<PackageMarker: drop, PackageWitness: drop>(
    self: &PackageAdmin<PackageMarker>,
    _: &AdminWitness<UnpauseAdmin<PackageMarker>>,
    _: PackageWitness,
    package_version: &mut PackageVersion<PackageMarker>,
    bits: u8,
) {
    package_version.assert_unpause_witness<_, PackageWitness>();
    assert!(self.upgrade.is_guarded(), blast_admin::errors::unguarded_upgrade_notice!());

    package_version.clear_pause_bits(bits);
}

/// Borrows the sealed Publisher for package `PackageMarker` itself, which passes a value of its
/// package witness, the type pinned at publication, to create Display or transfer policies for
/// its own types. The reference cannot move, mutate or burn the Publisher.
public fun publisher<PackageMarker: drop, PackageWitness: drop>(
    self: &PackageAdmin<PackageMarker>,
    _: PackageWitness,
    package_version: &PackageVersion<PackageMarker>,
): &Publisher {
    package_version.assert_publisher_witness<_, PackageWitness>();

    &self.publisher
}

// === Private Functions ===

/// Seals an already checked cap beside its Publisher, under the initial notice. The Publisher
/// needs no check: only the marker's one-time witness could have claimed it.
fun new<PackageMarker: drop>(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin<PackageMarker> {
    let id = object::new(ctx);
    let custodian_id = id.to_inner();
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_id = upgrade_cap.package();
    let native_version = upgrade_cap.version();
    let policy = upgrade_cap.policy();
    let upgrade = delayed_action::new(UpgradeKey<PackageMarker>(), &id, INITIAL_UPGRADE_DELAY_MS);

    let package_admin = PackageAdmin { id, publisher, upgrade_cap: option::some(upgrade_cap), upgrade };

    blast_admin_events::upgrade_custody_created<PackageMarker>(
        custodian_id,
        publisher_id,
        upgrade_cap_id,
        package_id,
        native_version,
        policy,
    );

    package_admin
}

// === Test-Only Functions ===

#[test_only]
/// Seals a consumer's test Publisher and unit-test UpgradeCap, left unshared and unchecked.
public fun new_for_testing<PackageMarker: drop>(
    publisher: Publisher,
    upgrade_cap: UpgradeCap,
    ctx: &mut TxContext,
): PackageAdmin<PackageMarker> {
    new(publisher, upgrade_cap, ctx)
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
public fun id_for_testing<PackageMarker: drop>(self: &PackageAdmin<PackageMarker>): ID {
    self.id.to_inner()
}

#[test_only]
public fun publisher_for_testing<PackageMarker: drop>(self: &PackageAdmin<PackageMarker>): &Publisher {
    &self.publisher
}

#[test_only]
public fun has_upgrade_cap_for_testing<PackageMarker: drop>(
    self: &PackageAdmin<PackageMarker>,
): bool {
    self.upgrade_cap.is_some()
}

#[test_only]
public fun upgrade_cap_id_for_testing<PackageMarker: drop>(self: &PackageAdmin<PackageMarker>): ID {
    object::id(self.upgrade_cap.borrow())
}

#[test_only]
public fun native_version_for_testing<PackageMarker: drop>(
    self: &PackageAdmin<PackageMarker>,
): u64 {
    self.upgrade_cap.borrow().version()
}

#[test_only]
public fun current_package_id_for_testing<PackageMarker: drop>(
    self: &PackageAdmin<PackageMarker>,
): ID {
    self.upgrade_cap.borrow().package()
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    blast_admin_events,
    delayed_action::{Self, DelayedAction},
    package_version::{PackageVersion, Publication}
};

use std::type_name;

use sui::{clock::Clock, package::{Self, Publisher, UpgradeCap, UpgradeReceipt, UpgradeTicket}};
