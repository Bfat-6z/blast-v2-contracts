// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::bootstrap_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const OTHER: address = @0xB0B;

// === Test-Only Types ===

public struct BootstrapFixture {
    scenario: Scenario,
    bootstrap: Option<marker::Bootstrap>,
    policy: lp_fee_policy::LpFeePolicy,
}

// === Tests ===

#[test]
fun publication_has_no_operational_version_before_custody_is_sealed() {
    let fixture = start();
    assert!(!fixture.has_version());
    fixture.end();
}

#[test]
fun initial_lp_policy_is_applied_immediately_and_reconstructible_from_events() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        let original = f.policy.protocol_destination();
        f.configure_policy(OTHER, bps::new(100), bps::new(200));
        let (meme, quote) = f.policy.shares<SUI>();
        assert_eq!(meme.value(), 100);
        assert_eq!(quote.value(), 200);
        assert_eq!(f.policy.protocol_destination(), OTHER);

        let events = sui::event::events_by_type<blast_events::LpFeeDestinationChanged>();
        assert_eq!(events.length(), 1);
        let mut expected = std::bcs::to_bytes(&original);
        expected.append(std::bcs::to_bytes(&@0xB0B));
        assert_eq!(std::bcs::to_bytes(&events[0]), expected);
        let events = sui::event::events_by_type<blast_events::LpFeePolicyChanged>();
        assert_eq!(events.length(), 1);
        let mut expected = std::bcs::to_bytes(&option::none<type_name::TypeName>());
        expected.append(std::bcs::to_bytes(&option::some(0u64)));
        expected.append(std::bcs::to_bytes(&option::some(0u64)));
        expected.append(std::bcs::to_bytes(&option::some(100u64)));
        expected.append(std::bcs::to_bytes(&option::some(200u64)));
        assert_eq!(std::bcs::to_bytes(&events[0]), expected);
        f.finish();
    });
    fixture.next_tx!(PUBLISHER, |f| {
        let version = f.take_version();
        assert_eq!(version.version_for_testing(), 1);
        assert_eq!(f.policy.protocol_destination(), OTHER);
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun finalization_permanently_removes_initial_policy_authority() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.finish());
    fixture.next_tx!(PUBLISHER, |f| { destroy(f.retake_bootstrap()); });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::delayed::ENotReady, location = blast_admin::delayed)]
fun later_lp_policy_changes_still_require_the_full_delay() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.finish());
    fixture.next_tx!(PUBLISHER, |f| {
        let version = f.take_version();
        let clock = sui::clock::create_for_testing(f.ctx!());
        f.policy.schedule_default_shares(&version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(1), bps::new(2), &clock);
        f.policy.apply_default_shares(&version, &clock);
        destroy(clock);
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = lp_fee_policy::EProtocolDestinationUnchanged, location = blast_fun_migrators::lp_fee_policy)]
fun bootstrap_rejects_a_zero_lp_destination() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_policy(@0x0, bps::new(0), bps::new(0)));
    fixture.end();
}

// === Test Helpers ===

fun start(): BootstrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    lp_fee_policy::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let bootstrap = option::some(scenario.take_from_sender());
    let policy = scenario.take_shared();
    BootstrapFixture { scenario, bootstrap, policy }
}

macro fun next_tx($fixture: &mut BootstrapFixture, $sender: address, $fn: |&mut BootstrapFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun ctx($fixture: &mut BootstrapFixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

fun configure_policy(self: &mut BootstrapFixture, destination: address, meme_bps: bps::Bps, quote_bps: bps::Bps) {
    self.policy.bootstrap(self.bootstrap.borrow(), destination, meme_bps, quote_bps);
}

fun finish(self: &mut BootstrapFixture) {
    let bootstrap = self.bootstrap.extract();
    let cap = sui::package::test_publish(@blast_fun_migrators.to_id(), self.ctx!());
    package_admin::wrap(bootstrap, cap, self.ctx!());
}

fun has_version(_: &BootstrapFixture): bool { test_scenario::has_most_recent_shared<marker::PackageVersion>() }
fun take_version(self: &BootstrapFixture): marker::PackageVersion { self.scenario.take_shared() }
fun retake_bootstrap(self: &BootstrapFixture): marker::Bootstrap { self.scenario.take_from_sender() }
fun end(self: BootstrapFixture) { destroy(self); }

// === Imports ===

use blast_admin::blast_acl;
use blast_fun::{blast_fun_domain::FeeAdmin, bps};
use blast_fun_migrators::{blast_fun_migrators as marker, blast_events, lp_fee_policy, package_admin};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{sui::SUI, test_scenario::{Self, Scenario}};
