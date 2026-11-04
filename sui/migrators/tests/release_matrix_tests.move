// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The release venue matrix: the launch policy and the vault registry each admit exactly the Cetus
/// and Bluefin venue witnesses, two distinct types. That no other module declares a venue witness
/// or reaches the hand-off is proven by the migrator source gate, not by this test.
module blast_fun_migrators::release_matrix_tests;

// === Test-Only Types ===

public struct MatrixFixture {
    scenario: Scenario,
    version: PackageVersion,
    config: LaunchConfig,
    registry: VaultRegistry,
    vault_version: VaultVersion<BLAST_VAULT_PACKAGE>,
    clock: Clock,
}

// === Tests ===

#[test]
fun the_launch_policy_admits_exactly_the_cetus_and_bluefin_venues() {
    let mut f = start();

    f.admit_launch_venue<cetus::Venue>();
    f.admit_launch_venue<bluefin::Venue>();

    let venues = f.config.venues_for_testing().members();
    assert_eq!(f.config.allowed_venue_count_for_testing(), 2);
    assert!(venues.contains(&type_name::with_original_ids<cetus::Venue>()));
    assert!(venues.contains(&type_name::with_original_ids<bluefin::Venue>()));
    f.end();
}

#[test]
fun the_vault_registry_admits_exactly_the_cetus_and_bluefin_venues() {
    let mut f = start();

    f.admit_vault_venue<cetus::Venue>();
    f.admit_vault_venue<bluefin::Venue>();

    let admitted = event::events_by_type<SetApplied<VenuesKey, TypeName>>().map!(|applied| {
        let (_, _, change, _) = applied.set_applied_fields();
        change.member_for_testing().destroy_some()
    });
    assert_eq!(
        admitted,
        vector[
            type_name::with_original_ids<cetus::Venue>(),
            type_name::with_original_ids<bluefin::Venue>(),
        ],
    );
    f.end();
}

// === Test Helpers ===

fun start(): MatrixFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();

    MatrixFixture {
        version: package_version::new_for_testing(ctx),
        config: launch_config::new_zero_fees_for_testing(ctx),
        registry: blast_vault_package::empty_registry_for_testing(ctx),
        vault_version: blast_vault_package::version_for_testing(ctx),
        clock: clock::create_for_testing(ctx),
        scenario,
    }
}

fun admit_launch_venue<Venue: drop>(self: &mut MatrixFixture) {
    self
        .config
        .set_venue_allowed_for_testing<Venue>(
            &self.version,
            &blast_acl::witness_for_testing<AdapterAdmin>(),
            true,
            self.scenario.ctx(),
        );
}

/// Schedules and applies `Venue`'s admission at the registry's publication notice of zero.
fun admit_vault_venue<Venue: drop>(self: &mut MatrixFixture) {
    let admin = blast_acl::witness_for_testing<VaultAdapterAdmin>();
    self.registry.schedule_venue<Venue>(&admin, &self.vault_version, &self.clock);
    self.registry.apply_venue<Venue>(&self.vault_version, &self.clock);
}

fun end(self: MatrixFixture) {
    let MatrixFixture { scenario, version, config, registry, vault_version, clock } = self;
    destroy(version);
    destroy(config);
    destroy(registry);
    destroy(vault_version);
    clock.destroy_for_testing();
    scenario.end();
}

// === Constants ===

const ADMIN: address = @0xAD;

// === Imports ===

use blast_admin::{
    blast_acl,
    delayed_set::SetApplied,
    package_version::PackageVersion as VaultVersion
};

use blast_core::blast_domain::AdapterAdmin as VaultAdapterAdmin;

use blast_fun::{
    blast_fun::{Self as package_version, PackageVersion},
    blast_fun_domain::AdapterAdmin,
    launch_config::{Self, LaunchConfig}
};

use blast_fun_migrators::{bluefin, cetus};

use blast_vault::blast_vault_package::{Self, BLAST_VAULT_PACKAGE, VaultRegistry, VenuesKey};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};
