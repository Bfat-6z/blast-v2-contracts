// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::admin_delay_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

public struct Adapter has drop {}
public struct OtherAdapter has drop {}
public struct LaterAdapter has drop {}

public struct AdminDelayFixture {
    scenario: Scenario,
    version: PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: Clock,
    config: creation_policy::CreationPolicy,
    runtime: fee_policy::FeePolicy,
}

// === Tests ===

#[test]
fun publication_setup_enables_different_notices_for_independent_operations() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.schedule_fee(123, 100);
        f.apply_fee();
        assert_eq!(f.fee(), 123);
        assert_eq!(f.clock.timestamp_ms(), 0);
        f.schedule_fee(456, 25);
        f.clock.set_for_testing(100);
        f.apply_fee();
        assert_eq!(f.fee(), 456);
        f.schedule_fee(789, 25);
        f.clock.set_for_testing(125);
        f.apply_fee();
        assert_eq!(f.fee(), 789);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun zero_next_delay_cannot_bypass_the_applied_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.schedule_fee(123, 100);
        f.apply_fee();
        f.schedule_fee(456, 0);
        f.clock.set_for_testing(99);
        f.apply_fee();
    });
    fixture.end();
}

#[test]
fun delay_only_change_keeps_the_value_and_cancel_keeps_the_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.schedule_fee(123, 100);
        f.apply_fee();
        f.schedule_fee(123, 25);
        f.clock.set_for_testing(100);
        f.cancel_fee();
        assert_eq!(f.fee(), 123);
        f.schedule_fee(123, 25);
        f.clock.set_for_testing(200);
        f.apply_fee();
        assert_eq!(f.fee(), 123);
        f.schedule_fee(456, 25);
        f.clock.set_for_testing(225);
        f.apply_fee();
        assert_eq!(f.fee(), 456);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun replacing_a_ready_proposal_restarts_the_old_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.schedule_fee(123, 100);
        f.apply_fee();
        f.schedule_fee(456, 0);
        f.clock.set_for_testing(100);
        f.schedule_fee(789, 0);
        f.clock.set_for_testing(199);
        f.apply_fee();
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_delay_change_rejects_before_other_validation() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.version.set_generation_for_testing(9);
        f.schedule_fee(0, 0);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed_set,
)]
fun a_fresh_adapter_type_cannot_bypass_the_admission_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<AdapterAdmin>();
        f.config.schedule_venue_delay(&f.version, &witness, 100, &f.clock);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.schedule_venue<Adapter>(&f.version, &witness, &f.clock);
        f.clock.set_for_testing(99);
        f.config.apply_venue<Adapter>(&f.version, &f.clock);
    });
    fixture.end();
}

#[test]
fun old_admissions_preserve_a_new_policy_in_either_application_order() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<AdapterAdmin>();
        f.config.schedule_venue<Adapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue_delay(&f.version, &witness, 100, &f.clock);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.apply_venue<Adapter>(&f.version, &f.clock);
        assert_eq!(f.config.venue_delay_ms_for_testing(), 100);

        f.config.schedule_venue<OtherAdapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue_delay(&f.version, &witness, 25, &f.clock);
        f.clock.set_for_testing(100);
        f.config.apply_venue<OtherAdapter>(&f.version, &f.clock);
        assert_eq!(f.config.venue_delay_ms_for_testing(), 100);
        f.config.apply_venue_delay(&f.version, &f.clock);
        assert_eq!(f.config.venue_delay_ms_for_testing(), 25);

        assert_eq!(migration_delay_changes(), 2);
    });
    fixture.end();
}

#[test]
fun multiple_admissions_cannot_restore_a_superseded_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<AdapterAdmin>();
        f.config.schedule_venue_delay(&f.version, &witness, 100, &f.clock);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.schedule_venue<Adapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue<OtherAdapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue_delay(&f.version, &witness, 25, &f.clock);

        f.clock.set_for_testing(100);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.apply_venue<OtherAdapter>(&f.version, &f.clock);
        f.config.apply_venue<Adapter>(&f.version, &f.clock);
        assert_eq!(f.config.venue_delay_ms_for_testing(), 25);

        f.config.schedule_venue<LaterAdapter>(&f.version, &witness, &f.clock);
        f.clock.set_for_testing(125);
        f.config.apply_venue<LaterAdapter>(&f.version, &f.clock);
        assert_eq!(f.config.venue_delay_ms_for_testing(), 25);
        assert_eq!(migration_delay_changes(), 2);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed_set,
)]
fun applying_an_old_admission_cannot_shorten_a_new_admissions_wait() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<AdapterAdmin>();
        f.config.schedule_venue<Adapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue_delay(&f.version, &witness, 100, &f.clock);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.apply_venue<Adapter>(&f.version, &f.clock);
        f.config.schedule_venue<OtherAdapter>(&f.version, &witness, &f.clock);

        f.clock.set_for_testing(99);
        f.config.apply_venue<OtherAdapter>(&f.version, &f.clock);
    });
    fixture.end();
}

#[test]
fun cancelling_policy_does_not_cancel_admission_or_change_its_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<AdapterAdmin>();
        f.config.schedule_venue_delay(&f.version, &witness, 100, &f.clock);
        f.config.apply_venue_delay(&f.version, &f.clock);
        f.config.schedule_venue<Adapter>(&f.version, &witness, &f.clock);
        f.config.schedule_venue_delay(&f.version, &witness, 0, &f.clock);
        f.clock.set_for_testing(100);
        f.config.cancel_venue_delay(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        f.config.apply_venue<Adapter>(&f.version, &f.clock);

        assert_eq!(f.config.venue_delay_ms_for_testing(), 100);
        assert_eq!(migration_delay_changes(), 1);
    });
    fixture.end();
}

// === Test Helpers ===

macro fun run($fixture: &mut AdminDelayFixture, $fn: |&mut AdminDelayFixture|) {
    let fixture = $fixture;
    $fn(fixture);
}

fun end(self: AdminDelayFixture) {
    destroy(self);
}

fun start(): AdminDelayFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    creation_policy::init_for_testing(scenario.ctx());
    fee_policy::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<Publication<BLAST_PRESALE_PACKAGE>>();
    let cap = sui::package::test_publish(@blast_presale.to_id(), scenario.ctx());
    package_admin::wrap(publication, cap, scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let version = scenario.take_shared();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    AdminDelayFixture {
        version,
        clock,
        config: scenario.take_shared(),
        runtime: scenario.take_shared(),
        scenario
    }
}


fun schedule_fee(self: &mut AdminDelayFixture, value: u64, delay_ms: u64) {
    self
        .runtime
        .schedule_fees(
            &self.version,
            &blast_acl::witness_for_testing<FeeAdmin>(),
            bps::new(value),
            bps::new(0),
            bps::new(0),
            bps::new(0),
            delay_ms,
            &self.clock
        );
}
fun apply_fee(self: &mut AdminDelayFixture) { self.runtime.apply_fees(&self.version, &self.clock); }
fun cancel_fee(self: &mut AdminDelayFixture) {
    self.runtime.cancel_fees(&self.version, &blast_acl::witness_for_testing<CancelAdmin>());
}
fun fee(self: &AdminDelayFixture): u64 { self.runtime.fees().raise_bps().value() }

/// Counts applied admission-notice changes, ignoring applied admissions.
fun migration_delay_changes(): u64 {
    sui::event::events_by_type<SetApplied<VenueKey, TypeName>>().count!(|applied| {
        let (_, _, change, _) = applied.set_applied_fields();
        change.member_for_testing().is_none()
    })
}


// === Imports ===

use blast_admin::{
    blast_acl,
    delayed_set::SetApplied,
    package_admin,
    package_version::{PackageVersion, Publication}
};

use blast_core::{blast_domain::{AdapterAdmin, CancelAdmin, FeeAdmin}, bps};

use blast_presale::{
    blast_presale_package::{Self as marker, BLAST_PRESALE_PACKAGE},
    creation_policy::{Self, VenueKey},
    fee_policy
};

use std::{type_name::TypeName, unit_test::{assert_eq, destroy}};

use sui::{clock::Clock, test_scenario::{Self, Scenario}};
