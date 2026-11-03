// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::admin_delay_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
/// The upgrade notice `package_admin::wrap` applies at publication.
const PUBLICATION_UPGRADE_NOTICE_MS: u64 = 172_800_000;

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

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun an_upgrade_scheduled_at_publication_waits_the_48_hour_notice() {
    let mut fixture = start();
    fixture.run!(|f| {
        assert_eq!(f.admin.upgrade_delay_ms(), PUBLICATION_UPGRADE_NOTICE_MS);
        let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
        let digest = vector::tabulate!(32, |_| 1u8);
        f.admin.schedule_upgrade(&f.version, &witness, digest, &f.clock);
        let scheduled = sui::event::events_by_type<ActionScheduled<UpgradeKey, UpgradeAction>>();
        assert_eq!(scheduled.length(), 1);
        let (_, _, _, delay_ms, ready_at_ms) = scheduled[0].action_scheduled_fields();
        assert_eq!(delay_ms, PUBLICATION_UPGRADE_NOTICE_MS);
        assert_eq!(ready_at_ms, PUBLICATION_UPGRADE_NOTICE_MS);

        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS - 1);
        let ticket = f.admin.authorize_upgrade(&f.version, &witness, digest, &f.clock);
        destroy(ticket);
    });
    fixture.end();
}

#[test]
fun upgrade_policy_only_application_and_cancellation_preserve_custody() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.replace_publication_upgrade_notice(100);
        let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 0, &f.clock);
        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS + 100);
        f.admin.cancel_upgrade_action(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        assert_eq!(f.admin.upgrade_delay_ms(), 100);
        f.admin.schedule_upgrade_delay(&f.version, &witness, 25, &f.clock);
        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS + 200);
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
        f.replace_publication_upgrade_notice(100);
        let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 0, &f.clock);
        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS + 99);
        f.admin.apply_upgrade_delay(&f.version, &f.clock);
    });
    fixture.end();
}

#[test]
fun an_upgrade_action_replaces_a_delay_proposal_without_changing_policy() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.replace_publication_upgrade_notice(100);
        let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 25, &f.clock);

        let digest = vector::tabulate!(32, |_| 1u8);
        f.admin.schedule_upgrade(&f.version, &witness, digest, &f.clock);
        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS + 100);
        let ticket = f.admin.authorize_upgrade(&f.version, &witness, digest, &f.clock);
        destroy(ticket);

        assert_eq!(f.admin.upgrade_delay_ms(), 100);
        assert!(f.admin.has_upgrade_cap_for_testing());
        assert_eq!(upgrade_delay_changes(), 1);
    });
    fixture.end();
}

#[test]
fun immutability_keeps_the_applied_notice_without_applying_a_replaced_policy() {
    let mut fixture = start();
    fixture.run!(|f| {
        f.replace_publication_upgrade_notice(100);
        let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
        f.admin.schedule_upgrade_delay(&f.version, &witness, 0, &f.clock);
        f.admin.schedule_make_immutable(&f.version, &witness, &f.clock);

        f.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS + 100);
        f.admin.make_immutable(&f.version, &witness, &f.clock);
        assert_eq!(f.admin.upgrade_delay_ms(), 100);
        assert!(!f.admin.has_upgrade_cap_for_testing());
        assert_eq!(upgrade_delay_changes(), 1);
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
    AdminDelayFixture {
        admin: scenario.take_shared(),
        version,
        clock,
        policy: scenario.take_shared(),
        scenario
    }
}

/// Replaces the publication upgrade notice with `delay_ms` once that notice has elapsed.
fun replace_publication_upgrade_notice(self: &mut AdminDelayFixture, delay_ms: u64) {
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    self.admin.schedule_upgrade_delay(&self.version, &witness, delay_ms, &self.clock);
    self.clock.set_for_testing(PUBLICATION_UPGRADE_NOTICE_MS);
    self.admin.apply_upgrade_delay(&self.version, &self.clock);
    assert_eq!(self.admin.upgrade_delay_ms(), delay_ms);
}

fun schedule_fee(self: &mut AdminDelayFixture, value: u64, delay_ms: u64) {
    self
        .policy
        .schedule_default_shares(
            &self.version,
            &blast_acl::witness_for_testing<FeeAdmin>(),
            bps::new(value),
            bps::new(0),
            delay_ms,
            &self.clock
        );
}
fun apply_fee(self: &mut AdminDelayFixture) { self.policy.apply_default_shares(&self.version, &self.clock); }
fun cancel_fee(self: &mut AdminDelayFixture) {
    self
        .policy
        .cancel_default_shares(&self.version, &blast_acl::witness_for_testing<CancelAdmin>());
}
fun fee(self: &AdminDelayFixture): u64 {
    { let (meme, _) = self.policy.shares<SUI>(); meme.value() }
}
fun configure_destination(self: &mut AdminDelayFixture) {
    self
        .policy
        .schedule_protocol_destination(
            &self.version,
            &blast_acl::witness_for_testing<TreasuryAdmin>(),
            @0xB0B,
            200,
            &self.clock
        );
    self.policy.apply_protocol_destination(&self.version, &self.clock);
    assert_eq!(self.policy.protocol_destination(), @0xB0B);
}

/// Counts applied upgrade-notice changes, ignoring consumed upgrade actions.
fun upgrade_delay_changes(): u64 {
    sui::event::events_by_type<ActionApplied<UpgradeKey, UpgradeAction>>().count!(|applied| {
        let (_, _, change, _) = applied.action_applied_fields();
        change.action().is_none()
    })
}

// === Imports ===

use blast_admin::{blast_acl, delayed_action::{ActionApplied, ActionScheduled}};
use blast_fun_migrators::{
    blast_fun_migrators as marker,
    lp_fee_policy,
    package_admin::{Self, UpgradeAction, UpgradeKey},
};
use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin, UpgradeAdmin}, bps};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::Clock, sui::SUI, test_scenario::{Self, Scenario}};
