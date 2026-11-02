// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::admin_delay_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Test-Only Types ===

public struct Adapter has drop {}

public struct AdminDelayFixture {
    scenario: Scenario,
    admin: package_admin::PackageAdmin,
    version: marker::PackageVersion,
    clock: Clock,
    policy: lp_fee_policy::LpFeePolicy,
}

// === Tests ===

#[test]
fun publication_setup_enables_different_notices_for_independent_operations() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.schedule_fee(123, 100);
        f.apply_fee();
        assert_eq!(f.fee(), 123);
        f.configure_destination();
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

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
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

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
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

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_delay_change_rejects_before_other_validation() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.version.set_for_testing(9);
        f.schedule_fee(0, 0);
    });
    fixture.end();
}

#[test]
fun upgrade_policy_only_application_and_cancellation_preserve_custody() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<blast_fun::blast_fun_domain::UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 100, &f.clock);
        f.admin.apply_upgrade_delay(&f.version, &f.clock);
        assert_eq!(f.admin.upgrade_delay_ms(), 100);
        f.admin.schedule_upgrade_delay(&f.version, &witness, 0, &f.clock);
        f.clock.set_for_testing(100);
        f.admin.cancel_upgrade_action(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        assert_eq!(f.admin.upgrade_delay_ms(), 100);
        f.admin.schedule_upgrade_delay(&f.version, &witness, 25, &f.clock);
        f.clock.set_for_testing(200);
        f.admin.apply_upgrade_delay(&f.version, &f.clock);
        assert_eq!(f.admin.upgrade_delay_ms(), 25);
        assert!(f.admin.has_upgrade_cap_for_testing());
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun upgrade_policy_only_reduction_cannot_be_applied_early() {
    let mut fixture = start();
    fixture.run!(|f| {
        let witness = blast_acl::witness_for_testing<blast_fun::blast_fun_domain::UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 100, &f.clock);
        f.admin.apply_upgrade_delay(&f.version, &f.clock);
        f.admin.schedule_upgrade_delay(&f.version, &witness, 0, &f.clock);
        f.clock.set_for_testing(99);
        f.admin.apply_upgrade_delay(&f.version, &f.clock);
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
    lp_fee_policy::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<marker::Publication>();
    let cap = sui::package::test_publish(@blast_fun_migrators.to_id(), scenario.ctx());
    package_admin::wrap(publication, cap, scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let version = scenario.take_shared();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    AdminDelayFixture { admin: scenario.take_shared(), version, clock, policy: scenario.take_shared(), scenario }
}

fun schedule_fee(self: &mut AdminDelayFixture, value: u64, delay_ms: u64) { self.policy.schedule_default_shares(&self.version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(value), bps::new(0), delay_ms, &self.clock); }
fun apply_fee(self: &mut AdminDelayFixture) { self.policy.apply_default_shares(&self.version, &self.clock); }
fun cancel_fee(self: &mut AdminDelayFixture) { self.policy.cancel_default_shares(&self.version, &blast_acl::witness_for_testing<CancelAdmin>()); }
fun fee(self: &AdminDelayFixture): u64 { { let (meme, _) = self.policy.shares<SUI>(); meme.value() } }
fun configure_destination(self: &mut AdminDelayFixture) {
    self.policy.schedule_protocol_destination(&self.version, &blast_acl::witness_for_testing<TreasuryAdmin>(), @0xB0B, 200, &self.clock);
        self.policy.apply_protocol_destination(&self.version, &self.clock);
    assert_eq!(self.policy.protocol_destination(), @0xB0B);
}

// === Imports ===

use blast_admin::blast_acl;
use blast_fun_migrators::{blast_fun_migrators as marker, lp_fee_policy, package_admin};
use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::Clock, sui::SUI, test_scenario::{Self, Scenario}};
