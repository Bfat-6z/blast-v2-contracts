// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::bootstrap_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const OTHER: address = @0xB0B;

// === Test-Only Types ===

public struct Adapter has drop {}

public struct BootstrapFixture {
    scenario: Scenario,
    bootstrap: Option<marker::Bootstrap>,
    config: launch_config::LaunchConfig,
    runtime: runtime_config::RuntimeConfig,
}

// === Tests ===

#[test]
fun initial_policy_is_live_immediately_and_events_reconstruct_every_value() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        f.configure_launch_policy(bps::new(100), bps::new(200), bps::new(300), bps::new(400), 123);
        f.configure_runtime(claim_key(), bps::new(500), OTHER);
        f.allow_initial_route();

        let (quote_fee, meme_fee) = f.config.snapshot_for_launch<SUI>(type_name::with_original_ids<Adapter>(), 9);
        assert_eq!(quote_fee.value(), 100);
        assert_eq!(meme_fee.value(), 200);
        assert_eq!(f.config.creation_fee(), 123);
        assert_eq!(f.config.protocol_allocation().meme_bps().value(), 300);
        assert_eq!(f.config.protocol_allocation().quote_bps().value(), 400);
        assert_eq!(f.runtime.treasury(), OTHER);
        assert_eq!(f.runtime.protocol_fee_share().value(), 500);
        assert_eq!(*f.runtime.creator_claim_signer(), claim_key());

        assert_payload<events::LaunchTradeFeesChanged>(pair(100, 200));
        assert_payload<events::ProtocolAllocationSet>(pair(300, 400));
        assert_payload<events::CreationFeeChanged>(std::bcs::to_bytes(&123u64));
        assert_payload<events::ProtocolFeeShareChanged>(std::bcs::to_bytes(&500u64));
        assert_payload<events::TreasuryChanged>(std::bcs::to_bytes(&@0xB0B));
        assert_payload<events::CreatorClaimSignerSet>(std::bcs::to_bytes(&claim_key()));
        assert_allowance<events::QuoteSet>(type_name::with_original_ids<SUI>(), true);
        assert_allowance<events::MigrationWitnessSet>(type_name::with_original_ids<Adapter>(), true);
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
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::valid_pause_bits!());
        version.assert_not_paused(constants::valid_pause_bits!());
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::valid_pause_bits!());
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::valid_pause_bits!());
        assert!(!f.has_bootstrap());
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun finalization_starts_with_every_operation_paused() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| { f.allow_initial_route(); f.finish(); });
    fixture.next_tx!(PUBLISHER, |f| {
        let version = f.take_version();
        version.assert_not_paused(constants::valid_pause_bits!());
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
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::valid_pause_bits!());
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::valid_pause_bits!());
        destroy(f.retake_bootstrap());
        destroy(version);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun finalization_rejects_an_empty_quote_allowlist() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.finish());
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EMigrationWitnessNotAllowed, location = blast_fun::launch_config)]
fun finalization_rejects_an_empty_adapter_allowlist() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| {
        f.allow_quote<SUI>(true);
        f.finish();
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidMigrationWitnessType, location = blast_fun::launch_config)]
fun bootstrap_rejects_a_constructible_primitive_adapter() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.allow_adapter<u64>(true));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidTradeFeeBps, location = blast_fun::launch_config)]
fun bootstrap_cannot_skip_trade_fee_bounds() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_launch_policy(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), 0));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidProtocolAllocation, location = blast_fun::launch_config)]
fun bootstrap_cannot_skip_allocation_bounds() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_launch_policy(bps::new(0), bps::new(0), bps::new(9_999), bps::new(0), 0));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidDestination, location = blast_fun::runtime_config)]
fun bootstrap_rejects_a_zero_treasury() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_runtime(claim_key(), bps::new(0), @0x0));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimPublicKey, location = blast_fun::runtime_config)]
fun bootstrap_rejects_a_malformed_claim_key() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| f.configure_runtime(vector[1], bps::new(0), OTHER));
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::delayed::ENotReady, location = blast_admin::delayed)]
fun a_repaused_protocol_still_delays_later_policy_changes() {
    let mut fixture = start();
    fixture.next_tx!(PUBLISHER, |f| { f.allow_initial_route(); f.finish(); });
    fixture.next_tx!(PUBLISHER, |f| {
        let mut version = f.take_version();
        version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::valid_pause_bits!());
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::valid_pause_bits!());
        let clock = sui::clock::create_for_testing(f.ctx!());
        f.config.schedule_creation_fee(&version, &blast_acl::witness_for_testing<FeeAdmin>(), 1, &clock);
        f.config.apply_creation_fee(&version, &clock);
        destroy(clock);
        destroy(version);
    });
    fixture.end();
}

// === Test Helpers ===

fun start(): BootstrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    runtime_config::init_for_testing(scenario.ctx());
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

fun configure_launch_policy(self: &mut BootstrapFixture, quote_fee_bps: bps::Bps, meme_fee_bps: bps::Bps, protocol_meme_bps: bps::Bps, protocol_quote_bps: bps::Bps, creation_fee: u64) {
    self.config.bootstrap(self.bootstrap.borrow(), quote_fee_bps, meme_fee_bps, protocol_meme_bps, protocol_quote_bps, creation_fee);
}

fun configure_runtime(self: &mut BootstrapFixture, claim_key: vector<u8>, share: bps::Bps, treasury: address) {
    self.runtime.bootstrap(self.bootstrap.borrow(), claim_key, share, treasury);
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
    let cap = sui::package::test_publish(@blast_fun.to_id(), self.ctx!());
    package_admin::wrap(bootstrap, cap, &self.config, self.ctx!());
}

fun take_version(self: &BootstrapFixture): marker::PackageVersion { self.scenario.take_shared() }
fun retake_bootstrap(self: &BootstrapFixture): marker::Bootstrap { self.scenario.take_from_sender() }
fun has_bootstrap(self: &BootstrapFixture): bool { self.scenario.has_most_recent_for_sender<marker::Bootstrap>() }
fun end(self: BootstrapFixture) { destroy(self); }

fun claim_key(): vector<u8> { x"1111111111111111111111111111111111111111111111111111111111111111" }

fun pair(first: u64, second: u64): vector<u8> {
    let mut expected = std::bcs::to_bytes(&first);
    expected.append(std::bcs::to_bytes(&second));
    expected
}

fun assert_payload<Payload: copy + drop>(expected: vector<u8>) {
    let emitted = sui::event::events_by_type<blast_fun::blast_events::Event<Payload>>();
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
use blast_fun::{blast_fun as marker, blast_fun_domain::{FeeAdmin, PauseAdmin, UnpauseAdmin}, bps, constants, events, launch_config, package_admin, runtime_config};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{sui::SUI, test_scenario::{Self, Scenario}};
