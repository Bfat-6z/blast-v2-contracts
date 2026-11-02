// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::admin_delay_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

public struct Adapter has drop {}

public struct AdminDelayFixture {
    scenario: Scenario,
    version: marker::PackageVersion,
    clock: Clock,
    config: creation_policy::CreationPolicy,
    runtime: fee_policy::FeePolicy,
}

// === Tests ===

#[test]
fun production_custody_starts_with_zero_delay_and_initial_configuration_uses_normal_roles() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        assert_eq!(f.version.admin_delay_ms(), 0);
        f.set_fee(123);
        assert_eq!(f.fee(), 123);
        f.configure_route_and_destinations();
        assert_eq!(f.clock.timestamp_ms(), 0);
        f.set_delay(100);
        assert_eq!(f.version.admin_delay_ms(), 100);
    });
    fixture.end();
}

#[test]
fun a_shorter_delay_waits_the_old_period_and_new_actions_use_the_applied_period() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(25);
        assert_eq!(f.version.admin_delay_ms(), 100);
        f.clock.set_for_testing(100);
        f.version.apply_admin_delay(&f.clock);
        assert_eq!(f.version.admin_delay_ms(), 25);
        f.schedule_fee(123);
        f.clock.set_for_testing(125);
        f.apply_fee();
        assert_eq!(f.fee(), 123);
    });
    fixture.end();
}

#[test]
fun existing_proposals_keep_their_threshold_when_the_policy_changes() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.schedule_fee(123);
        f.set_delay(100);
        f.apply_fee();
        assert_eq!(f.fee(), 123);
        f.schedule_delay(25);
        f.clock.set_for_testing(10);
        f.schedule_fee(456);
        f.clock.set_for_testing(100);
        f.version.apply_admin_delay(&f.clock);
        f.clock.set_for_testing(110);
        f.apply_fee();
        assert_eq!(f.fee(), 456);
    });
    fixture.end();
}

#[test]
fun returning_to_zero_waits_the_old_period_then_allows_same_clock_configuration() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(0);
        f.clock.set_for_testing(100);
        f.version.apply_admin_delay(&f.clock);
        assert_eq!(f.version.admin_delay_ms(), 0);
        f.set_fee(123);
        assert_eq!(f.fee(), 123);
    });
    fixture.end();
}

#[test]
fun cancellation_after_readiness_preserves_policy_and_replacement_restarts_notice() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(25);
        f.clock.set_for_testing(100);
        f.version.cancel_admin_delay(&blast_acl::witness_for_testing<CancelAdmin>());
        assert_eq!(f.version.admin_delay_ms(), 100);
        f.schedule_delay(200);
        f.clock.set_for_testing(150);
        f.schedule_delay(300);
        f.clock.set_for_testing(250);
        f.version.apply_admin_delay(&f.clock);
        assert_eq!(f.version.admin_delay_ms(), 300);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun a_reduction_cannot_apply_one_millisecond_before_the_old_deadline() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(1);
        f.clock.set_for_testing(99);
        f.version.apply_admin_delay(&f.clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun an_increase_cannot_apply_before_the_old_deadline() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(200);
        f.clock.set_for_testing(99);
        f.version.apply_admin_delay(&f.clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun a_policy_replacement_restarts_the_whole_old_notice() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(25);
        f.clock.set_for_testing(100);
        f.schedule_delay(50);
        f.clock.set_for_testing(199);
        f.version.apply_admin_delay(&f.clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun a_new_delay_cannot_shorten_an_earlier_pending_action() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.set_delay(100);
        f.schedule_delay(1);
        f.clock.set_for_testing(10);
        f.schedule_fee(123);
        f.clock.set_for_testing(100);
        f.version.apply_admin_delay(&f.clock);
        f.clock.set_for_testing(101);
        f.apply_fee();
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENoPending, location = blast_admin::delayed)]
fun applying_a_policy_change_twice_is_rejected() {
    let mut fixture = start();
    fixture.next_tx!(|f| { f.set_delay(100); f.version.apply_admin_delay(&f.clock); });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::ENoPending, location = blast_admin::delayed)]
fun a_cancelled_policy_change_cannot_be_applied() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.schedule_delay(100);
        f.version.cancel_admin_delay(&blast_acl::witness_for_testing<CancelAdmin>());
        f.version.apply_admin_delay(&f.clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = delayed::EDelayUnchanged, location = blast_admin::delayed)]
fun scheduling_an_unchanged_delay_is_rejected() {
    let mut fixture = start();
    fixture.next_tx!(|f| f.schedule_delay(0));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_schedule_rejects_before_unchanged_policy_validation() {
    let mut fixture = start();
    fixture.next_tx!(|f| { f.version.set_for_testing(9); f.schedule_delay(0); });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_apply_rejects_before_missing_proposal_validation() {
    let mut fixture = start();
    fixture.next_tx!(|f| { f.version.set_for_testing(9); f.version.apply_admin_delay(&f.clock); });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_cancel_rejects_before_missing_proposal_validation() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.version.set_for_testing(9);
        f.version.cancel_admin_delay(&blast_acl::witness_for_testing<CancelAdmin>());
    });
    fixture.end();
}

#[test]
fun delay_events_reconstruct_proposals_cancellation_and_final_policy() {
    let mut fixture = start();
    fixture.next_tx!(|f| {
        f.schedule_delay(100);
        assert_payload<Scheduled>(pair(100, 0));
        f.version.apply_admin_delay(&f.clock);
        assert_payload<Changed>(pair(0, 100));
    });
    fixture.next_tx!(|f| {
        f.schedule_delay(25);
        assert_payload<Scheduled>(pair(25, 100));
        f.version.cancel_admin_delay(&blast_acl::witness_for_testing<CancelAdmin>());
        assert_payload<Cancelled>(std::bcs::to_bytes(&25u64));
        assert_eq!(f.version.admin_delay_ms(), 100);
    });
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx($fixture: &mut AdminDelayFixture, $fn: |&mut AdminDelayFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx(PUBLISHER);
    $fn(fixture);
}

fun schedule_delay(self: &mut AdminDelayFixture, delay_ms: u64) {
    self.version.schedule_admin_delay(&blast_acl::witness_for_testing<UpgradeAdmin>(), delay_ms, &self.clock);
}

fun set_delay(self: &mut AdminDelayFixture, delay_ms: u64) {
    self.schedule_delay(delay_ms);
    self.version.apply_admin_delay(&self.clock);
}

fun set_fee(self: &mut AdminDelayFixture, value: u64) {
    self.schedule_fee(value);
    self.apply_fee();
}

fun end(self: AdminDelayFixture) { destroy(self); }

fun pair(first: u64, second: u64): vector<u8> {
    let mut expected = std::bcs::to_bytes(&first);
    expected.append(std::bcs::to_bytes(&second));
    expected
}

fun assert_payload<Payload: copy + drop>(expected: vector<u8>) {
    let emitted = sui::event::events_by_type<Payload>();
    assert_eq!(emitted.length(), 1);
    assert_eq!(std::bcs::to_bytes(&emitted[0]), expected);
}

fun start(): AdminDelayFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    creation_policy::init_for_testing(scenario.ctx());
    fee_policy::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<marker::Publication>();
    let cap = sui::package::test_publish(@blast_presale.to_id(), scenario.ctx());
    package_admin::wrap(publication, cap, scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let version = scenario.take_shared();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    AdminDelayFixture { version, clock, config: scenario.take_shared(), runtime: scenario.take_shared(), scenario }
}

fun schedule_fee(self: &mut AdminDelayFixture, value: u64) {
    self.runtime.schedule_fees(&self.version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(value), bps::new(0), bps::new(0), bps::new(0), &self.clock);
}
fun apply_fee(self: &mut AdminDelayFixture) { self.runtime.apply_fees(&self.version, &self.clock); }
fun fee(self: &AdminDelayFixture): u64 { self.runtime.fees().raise_bps().value() }
fun configure_route_and_destinations(self: &mut AdminDelayFixture) {
    self.config.set_quote_allowed<SUI>(&self.version, &blast_acl::witness_for_testing<ListingAdmin>(), true);
    self.config.schedule_migration_witness<Adapter>(&self.version, &blast_acl::witness_for_testing<AdapterAdmin>(), &self.clock);
    self.config.apply_migration_witness<Adapter>(&self.version, &self.clock);
    self.runtime.schedule_destination(&self.version, &blast_acl::witness_for_testing<TreasuryAdmin>(), @0xB0B, &self.clock);
    self.runtime.apply_destination(&self.version, &self.clock);
    assert_eq!(self.runtime.destination(), @0xB0B);
    self.config.assert_allowed<SUI, Adapter>();
}

// === Imports ===

use blast_admin::{blast_acl, delayed};
use blast_presale::{blast_presale_package as marker, bps, creation_policy, fee_policy, package_admin, blast_presale_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin, UpgradeAdmin, AdapterAdmin, ListingAdmin}, blast_presale_package::{AdminDelayScheduled as Scheduled, AdminDelayChanged as Changed, AdminDelayCancelled as Cancelled}};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::Clock, sui::SUI, test_scenario::{Self, Scenario}};
