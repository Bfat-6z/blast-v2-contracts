// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The migrators package's publication through `blast_admin`'s generic administration: it defines
/// no pause bits, emits nothing, and its custody binds only this package's own `UpgradeCap`. The
/// generic upgrade, pause, and delay matrices belong to `blast_admin`.
module blast_migrators::blast_migrators_tests;

// === Tests ===

#[test]
/// Wrapping the publication shares an unpaused version at version one with no pause bits.
fun wrapping_the_publication_shares_an_unpaused_version_without_pause_bits() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrators_package::init_for_testing(scenario.ctx());
    assert_eq!(scenario.next_tx(PUBLISHER).num_user_events(), 0);

    let publication = scenario.take_from_sender<Publication<BLAST_MIGRATORS>>();
    let upgrade_cap = package::test_publish(@blast_migrators.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let version = scenario.take_shared<PackageVersion<BLAST_MIGRATORS>>();
    assert_eq!(version.valid_pause_bits_for_testing(), 0);
    assert_eq!(version.paused_for_testing(), 0);
    assert_eq!(version.version_for_testing(), constants::version!());
    version.assert_current(constants::version!());
    test_scenario::return_shared(version);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::package_admin,
)]
/// The publication cannot seal another package's native upgrade authority.
fun the_publication_rejects_another_packages_upgrade_cap() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrators_package::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    let publication = scenario.take_from_sender<Publication<BLAST_MIGRATORS>>();
    let upgrade_cap = package::test_publish(@0xF0E1.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());

    abort
}

// === Constants ===

const PUBLISHER: address = @0xB1A57;

// === Imports ===

use blast_admin::{package_admin, package_version::{PackageVersion, Publication}};

use blast_migrators::{blast_migrators::{Self as migrators_package, BLAST_MIGRATORS}, constants};

use std::unit_test::assert_eq;

use sui::{package, test_scenario};
