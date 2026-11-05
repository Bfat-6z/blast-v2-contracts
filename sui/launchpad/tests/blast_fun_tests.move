// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::blast_fun_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

/// Custodies the publication delivered by production package initialization.
public struct PublicationFixture {
    scenario: Scenario,
    publication: Publication<BLAST_FUN>,
}

// === Tests ===

#[test]
fun package_init_retains_canonical_publisher_in_publication() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        assert!(f.publication.publisher_for_testing().from_module<BLAST_FUN>());
        assert!(f.publication.publisher_for_testing().from_package<BLAST_FUN>());
    });

    fixture.end();
}

#[test]
/// Publication shares no version; wrapping it shares the package version with every launchpad
/// bit paused and the generic package administration.
fun wrapping_the_publication_shares_a_fully_paused_version() {
    let fixture = start();
    assert!(!fixture.has_shared_version());

    let (paused, valid_pause_bits, generation) = fixture.wrap();

    assert_eq!(paused, constants::valid_pause_bits!());
    assert_eq!(valid_pause_bits, constants::valid_pause_bits!());
    assert_eq!(generation, constants::generation!());
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut PublicationFixture,
    $sender: address,
    $fn: |&mut PublicationFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): PublicationFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    otw::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<Publication<BLAST_FUN>>();

    PublicationFixture { scenario, publication }
}

fun has_shared_version(_: &PublicationFixture): bool {
    test_scenario::has_most_recent_shared<PackageVersion<BLAST_FUN>>()
}

/// Wraps the publication with a test upgrade cap and returns the shared version's paused bits,
/// defined bits, and generation; the scenario ends here.
fun wrap(self: PublicationFixture): (u8, u8, u64) {
    let PublicationFixture { mut scenario, publication } = self;
    let upgrade_cap = sui::package::test_publish(@blast_fun.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());

    scenario.next_tx(PUBLISHER);
    assert!(test_scenario::has_most_recent_shared<PackageAdmin<BLAST_FUN>>());
    let version = scenario.take_shared<PackageVersion<BLAST_FUN>>();
    let (paused, valid_pause_bits, generation) = (
        version.paused_for_testing(),
        version.valid_pause_bits_for_testing(),
        version.generation_for_testing(),
    );
    test_scenario::return_shared(version);
    scenario.end();

    (paused, valid_pause_bits, generation)
}

fun end(self: PublicationFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::{package_admin::{Self, PackageAdmin}, package_version::{PackageVersion, Publication}};

use blast_fun::{blast_fun::{Self as otw, BLAST_FUN}, constants};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
