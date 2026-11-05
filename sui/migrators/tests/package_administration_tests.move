// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Focused tests for the migrators package's own generation and sealed custody.
///
/// The reusable ACL, generation, and custody matrices belong to `blast_admin`.
/// These tests prove only that Migrators owns state independent of Launchpad,
/// gates its mutations on its own generation, and takes Launchpad's
/// upgrade-admin role for its own custody.
module blast_fun_migrators::package_administration_tests;

// === Test-Only Types ===

/// This package's own generation and custody.
public struct AdminFixtureState {
    scenario: Scenario,
    package_version: PackageVersion,
    package_admin: PackageAdmin,
}

// === Tests ===

#[test]
/// Migrators starts at its own generation one, independent of Launchpad's.
fun the_package_owns_one_independent_operational_generation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
/// Advancing Migrators alone does not touch any other package's generation.
fun advancing_this_package_leaves_its_own_container_at_the_next_generation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.advance_for_testing();

        assert_eq!(f.package_version.version_for_testing(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A retired generation cannot authorize an upgrade, even with the upgrade-admin role.
fun a_stale_generation_rejects_upgrade_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_version.set_for_testing(2);

        let ticket = f
            .package_admin
            .authorize_upgrade_for_testing(
                &f.package_version,
                &admin_witness,
                DIGEST,
                f.scenario.ctx()
            );
        assert_eq!(*ticket.ticket_digest(), DIGEST);
        destroy(ticket);
    });

    fixture.end();
}

#[test]
/// Launchpad's upgrade-admin role can issue the approved digest after the delay.
fun the_launchpad_upgrade_admin_reaches_this_packages_upgrade_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();

        let ticket = f
            .package_admin
            .authorize_upgrade_for_testing(
                &f.package_version,
                &admin_witness,
                DIGEST,
                f.scenario.ctx()
            );
        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
/// The publication Publication cannot seal another package's native upgrade authority.
fun a_cap_from_another_package_cannot_seal_the_package_custody() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| f.wrap_with_foreign_package_cap());

    fixture.end();
}

#[test]
fun committing_the_canonical_receipt_advances_the_operational_generation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let witness = upgrade_admin();
        let ticket = f.package_admin.authorize_upgrade_for_testing(
            &f.package_version,
            &witness,
            DIGEST,
            f.scenario.ctx(),
        );

        let receipt = ticket.test_upgrade();
        f.package_admin.commit_upgrade_and_advance(&mut f.package_version, &witness, receipt);

        assert_eq!(f.package_version.version_for_testing(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// The upgrade finalizer checks the generation before it touches the receipt.
fun commit_checks_the_generation_before_the_receipt() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        let receipt = f.foreign_receipt();
        f.package_version.set_for_testing(5);

        f.package_admin.commit_upgrade_and_advance(&mut f.package_version, &admin_witness, receipt);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun admin_next_tx(
    $fixture: &mut AdminFixtureState,
    $sender: address,
    $fn: |&mut AdminFixtureState|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): AdminFixtureState {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());

    AdminFixtureState { scenario, package_version, package_admin }
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin<BLAST_FUN_MIGRATORS>> {
    blast_acl::witness_for_testing()
}

/// Creates a native receipt belonging to a different upgrade capability.
fun foreign_receipt(self: &mut AdminFixtureState): UpgradeReceipt {
    let mut cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), self.scenario.ctx());
    let receipt = cap.authorize_upgrade(package::compatible_policy(), DIGEST).test_upgrade();
    destroy(cap);

    receipt
}

fun wrap_with_foreign_package_cap(self: &mut AdminFixtureState) {
    package_version::init_for_testing(self.scenario.ctx());
    self.scenario.next_tx(PUBLISHER);
    let bootstrap = self.scenario.take_from_sender<Publication>();
    let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), self.scenario.ctx());

    package_admin::wrap(bootstrap, upgrade_cap, self.scenario.ctx());
}

fun admin_end(self: AdminFixtureState) {
    destroy(self);
}

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// Any 32-byte package digest; custody rejects every other length before the cap is reached.
const DIGEST: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000000";

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, package_admin::UpgradeAdmin};

use blast_fun_migrators::{
    blast_fun_migrators::{Self as package_version, BLAST_FUN_MIGRATORS, PackageVersion, Publication},
    package_admin::{Self, PackageAdmin},
};

use std::unit_test::{assert_eq, destroy};

use sui::{package::{Self, UpgradeReceipt}, test_scenario::{Self, Scenario}};

use fun admin_end as AdminFixtureState.end;

use fun admin_next_tx as AdminFixtureState.next_tx;
