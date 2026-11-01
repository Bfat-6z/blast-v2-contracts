// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::bootstrap_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const OTHER: address = @0xB0B;

// === Test-Only Types ===

public struct Adapter has drop {}

public struct BootstrapFixture {
    scenario: Scenario,
    bootstrap: Option<marker::Bootstrap>,
    config: creation_policy::CreationPolicy,
    runtime: fee_policy::FeePolicy,
}

// === Tests ===

#[test]
fun initial_policy_is_live_immediately_and_events_reconstruct_every_value() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        f.configure_runtime(OTHER, bps::new(100), bps::new(200), bps::new(300), bps::new(400));
        f.allow_initial_route();
        f.config.assert_allowed<SUI, Adapter>();
        assert_eq!(f.runtime.destination(), OTHER);
        let fees = f.runtime.fees();
        assert_eq!(fees.raise_bps().value(), 100);
        assert_eq!(fees.token_bps().value(), 200);
        assert_eq!(fees.lp_fee_meme_bps().value(), 300);
        assert_eq!(fees.lp_fee_quote_bps().value(), 400);

        let mut expected = pair(100, 200);
        expected.append(pair(300, 400));
        assert_payload<fee_policy::FeesChanged>(expected);
        assert_payload<fee_policy::DestinationChanged>(std::bcs::to_bytes(&@0xB0B));
        assert_allowance<creation_policy::QuoteSet>(type_name::with_original_ids<SUI>(), true);
        assert_allowance<creation_policy::MigrationWitnessSet>(type_name::with_original_ids<Adapter>(), true);
    });
    fixture.end();
}

#[test]
fun finalization_consumes_bootstrap_and_unpause_needs_no_clock() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        f.allow_initial_route();
        f.finish();
        assert!(!f.has_initial_authority());
    });
    fixture.next_tx!(PUBLISHER, |f| {
        let mut version = f.take_version();
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 11);
        version.assert_not_paused(11);
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 11);
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 11);
        assert!(!f.has_bootstrap());
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun finalization_starts_with_every_operation_paused() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| { f.allow_initial_route(); f.finish(); });
    fixture.next_tx!(PUBLISHER, |f| {
        let version = f.take_version();
        version.assert_not_paused(11);
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun pause_and_unpause_cannot_restore_bootstrap_authority() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| { f.allow_initial_route(); f.finish(); });
    fixture.next_tx!(PUBLISHER, |f| {
        let mut version = f.take_version();
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 11);
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 11);
        destroy(f.retake_bootstrap());
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = creation_policy::EQuoteNotAllowed, location = blast_presale::creation_policy)]
fun finalization_rejects_an_empty_quote_allowlist() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.finish());
    fixture.end();
}

#[test]
#[expected_failure(abort_code = creation_policy::EMigrationWitnessNotAllowed, location = blast_presale::creation_policy)]
fun finalization_rejects_an_empty_adapter_allowlist() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        f.allow_quote<SUI>(true);
        f.finish();
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = creation_policy::EInvalidMigrationWitness, location = blast_presale::creation_policy)]
fun bootstrap_rejects_a_constructible_primitive_adapter() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.allow_adapter<u64>(true));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
fun bootstrap_cannot_skip_fee_bounds() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_runtime(OTHER, bps::new(10_000), bps::new(0), bps::new(0), bps::new(0)));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidDestination, location = blast_presale::fee_policy)]
fun bootstrap_rejects_a_zero_destination() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_runtime(@0x0, bps::new(0), bps::new(0), bps::new(0), bps::new(0)));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::delayed::ENotReady, location = blast_admin::delayed)]
fun a_repaused_protocol_still_delays_later_policy_changes() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| { f.allow_initial_route(); f.finish(); });
    fixture.next_tx!(PUBLISHER, |f| {
        let mut version = f.take_version();
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 11);
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 11);
        let clock = sui::clock::create_for_testing(f.ctx!());
        f.runtime.schedule_fees(&version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(1), bps::new(0), bps::new(0), bps::new(0), &clock);
        f.runtime.apply_fees(&version, &clock);
        destroy(clock);
        destroy(version);
    });
    fixture.end();
}

// === Test Helpers ===

fun start(): BootstrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    creation_policy::init_for_testing(scenario.ctx());
    fee_policy::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let bootstrap = option::some(scenario.take_from_sender());
    let config = scenario.take_shared();
    let runtime = scenario.take_shared();
    BootstrapFixture { scenario, bootstrap, config, runtime }
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

fun allow_initial_route(self: &mut BootstrapFixture) {
    self.config.bootstrap_quote<SUI>(self.bootstrap.borrow(), true);
    self.config.bootstrap_migration_witness<Adapter>(self.bootstrap.borrow(), true);
}

fun configure_runtime(self: &mut BootstrapFixture, destination: address, raise_bps: bps::Bps, token_bps: bps::Bps, meme_bps: bps::Bps, quote_bps: bps::Bps) {
    self.runtime.bootstrap(self.bootstrap.borrow(), destination, raise_bps, token_bps, meme_bps, quote_bps);
}

fun allow_quote<Quote>(self: &mut BootstrapFixture, allowed: bool) {
    self.config.bootstrap_quote<Quote>(self.bootstrap.borrow(), allowed);
}

fun allow_adapter<Witness: drop>(self: &mut BootstrapFixture, allowed: bool) {
    self.config.bootstrap_migration_witness<Witness>(self.bootstrap.borrow(), allowed);
}

fun has_initial_authority(self: &BootstrapFixture): bool { self.bootstrap.is_some() }

fun finish(self: &mut BootstrapFixture) {
    let bootstrap = self.bootstrap.extract();
    let cap = sui::package::test_publish(@blast_presale.to_id(), self.ctx!());
    package_admin::wrap(bootstrap, cap, &self.config, self.ctx!());
}

fun take_version(self: &BootstrapFixture): marker::PackageVersion { self.scenario.take_shared() }
fun retake_bootstrap(self: &BootstrapFixture): marker::Bootstrap { self.scenario.take_from_sender() }
fun has_bootstrap(self: &BootstrapFixture): bool { self.scenario.has_most_recent_for_sender<marker::Bootstrap>() }
fun end(self: BootstrapFixture) { destroy(self); }

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

fun assert_allowance<Payload: copy + drop>(kind: type_name::TypeName, allowed: bool) {
    let mut expected = std::bcs::to_bytes(&kind);
    expected.append(std::bcs::to_bytes(&allowed));
    assert_payload<Payload>(expected);
}

// === Imports ===

use blast_admin::blast_acl;
use blast_presale::{blast_presale_package as marker, blast_presale_domain::{FeeAdmin, PauseAdmin, UnpauseAdmin}, bps, creation_policy, fee_policy, package_admin};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{sui::SUI, test_scenario::{Self, Scenario}};
