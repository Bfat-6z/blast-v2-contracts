// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::runtime_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;


const ANYONE: address = @0xB0B;

/// The signer notice the fixture raises after its zero-notice bootstrap.
const NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

/// Live-settings administration under each setter's own role, with a clock for the signer set.
public struct ConfigFixture {
    scenario: Scenario,
    package_version: PackageVersion<BLAST_FUN>,
    config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
/// Package initialization admits no claim signer and splits trade fees 50/50. Its only events are
/// the primitives' creation records of the two delayed settings.
fun package_init_uses_a_half_protocol_share_without_signer() {
    let (events, signer_public_keys, protocol_fee_share_bps) = published_config();

    assert_eq!(events, 2);
    assert!(signer_public_keys.is_empty());
    assert_eq!(protocol_fee_share_bps, 5_000);
}

// --- Protocol fee share ---

#[test]
fun admin_sets_the_protocol_fee_share_and_it_emits_the_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share_for_testing(bps::new(7_000));

        assert_eq!(f.config.protocol_fee_share().value(), 7_000);
        assert_eq!(
            bcs::to_bytes(&applied_one<ProtocolFeeShareKey, Bps>()),
            bcs::to_bytes(&7_000u64),
        );
    });

    fixture.end();
}

#[test]
fun protocol_fee_share_accepts_zero_and_its_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share_for_testing(bps::new(7_000));
        assert_eq!(f.config.protocol_fee_share().value(), 7_000);

        f.set_protocol_fee_share_for_testing(bps::new(0));
        assert_eq!(f.config.protocol_fee_share().value(), 0);

        let changes = applied<ProtocolFeeShareKey, Bps>();
        assert_eq!(changes.length(), 2);
        assert_eq!(bcs::to_bytes(&changes[0]), bcs::to_bytes(&7_000u64));
        assert_eq!(bcs::to_bytes(&changes[1]), bcs::to_bytes(&0u64));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidProtocolFeeShare, location = blast_fun::runtime_config)]
fun protocol_fee_share_rejects_one_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share_for_testing(bps::new(7_001));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun protocol_fee_share_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share_for_testing(bps::new(0));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun protocol_fee_share_checks_the_version_before_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_generation_for_testing(2);

        f.set_protocol_fee_share_for_testing(bps::new(0));
    });

    fixture.end();
}

// --- Creator-claim signer ---

#[test]
/// Admission waits the applied notice; once ready, any sender applies it and the key signs.
fun a_signer_key_waits_the_notice_and_anyone_applies_it() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());

        assert!(f.config.creator_claim_signers().is_empty());
        let (_, _, change, delay_ms, ready_at_ms) = scheduled_one().set_scheduled_fields();
        assert_eq!(change.member(), option::some(signer_public_key()));
        assert_eq!(delay_ms, NOTICE_MS);
        assert_eq!(ready_at_ms, NOTICE_MS);
    });

    fixture.next_tx!(ANYONE, |f| {
        f.clock.set_for_testing(NOTICE_MS);
        f.apply_creator_claim_signer(signer_public_key());

        assert_eq!(f.config.creator_claim_signers(), vector[signer_public_key()]);
        let (_, _, change, delay_ms) = applied_one_signer().set_applied_fields();
        assert_eq!(change.member(), option::some(signer_public_key()));
        assert_eq!(delay_ms, NOTICE_MS);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun a_signer_key_cannot_apply_before_the_notice() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());
        f.clock.set_for_testing(NOTICE_MS - 1);

        f.apply_creator_claim_signer(signer_public_key());
    });

    fixture.end();
}

#[test]
/// Publication's zero notice admits the first key in the bootstrap transaction; raising the
/// notice there makes every later key wait it.
fun zero_notice_bootstrap_admits_at_once_then_the_raised_notice_applies() {
    let (signer_public_keys, second_admission) = bootstrapped_signers(5);

    assert_eq!(signer_public_keys, vector[signer_public_key()]);
    let (_, _, change, delay_ms, ready_at_ms) = second_admission.set_scheduled_fields();
    assert_eq!(change.member(), option::some(second_signer_public_key()));
    assert_eq!(delay_ms, NOTICE_MS);
    assert_eq!(ready_at_ms, 5 + NOTICE_MS);
}

#[test]
/// Revocation removes a live key in the same transaction, without waiting any notice.
fun revoke_removes_a_live_key_at_once() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.admit_creator_claim_signer(signer_public_key());
        f.admit_creator_claim_signer(second_signer_public_key());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.revoke_creator_claim_signer(signer_public_key());

        assert_eq!(f.config.creator_claim_signers(), vector[second_signer_public_key()]);
        let removed = event::events_by_type<MemberRemoved<ClaimSignerKey, vector<u8>>>();
        assert_eq!(removed.length(), 1);
        let (_, _, member) = removed[0].member_removed_fields();
        assert_eq!(member, signer_public_key());
    });

    fixture.end();
}

#[test]
/// Revoking a pending key discards its admission at once and admits nothing.
fun revoke_discards_a_pending_key_at_once() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.revoke_creator_claim_signer(signer_public_key());

        assert!(f.config.creator_claim_signers().is_empty());
        assert!(event::events_by_type<MemberRemoved<ClaimSignerKey, vector<u8>>>().is_empty());
        let (_, _, change, _, ready_at_ms) = cancelled_one_signer().set_cancelled_fields();
        assert_eq!(change.member(), option::some(signer_public_key()));
        assert_eq!(ready_at_ms, NOTICE_MS);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_revoked_pending_key_cannot_apply() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());
        f.revoke_creator_claim_signer(signer_public_key());
        f.clock.set_for_testing(NOTICE_MS);

        f.apply_creator_claim_signer(signer_public_key());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_set)]
fun revoking_an_unknown_key_rejects() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.admit_creator_claim_signer(signer_public_key());

        f.revoke_creator_claim_signer(second_signer_public_key());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_set)]
fun scheduling_an_admitted_key_rejects() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.admit_creator_claim_signer(signer_public_key());

        f.schedule_creator_claim_signer(signer_public_key());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimPublicKey, location = blast_fun::runtime_config)]
fun claim_signer_rejects_a_key_that_is_not_32_bytes() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(x"00");
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun claim_signer_checks_the_version_before_the_key_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_generation_for_testing(2);

        f.schedule_creator_claim_signer(x"00");
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ETooManyClaimSigners, location = blast_fun::runtime_config)]
/// Live and pending keys share the cap of four.
fun the_fifth_signer_key_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.fill_creator_claim_signers();

        f.schedule_creator_claim_signer(fifth_signer_public_key());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimPublicKey, location = blast_fun::runtime_config)]
/// The key length is checked before the cap.
fun claim_signer_checks_the_key_length_before_the_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.fill_creator_claim_signers();

        f.schedule_creator_claim_signer(x"00");
    });

    fixture.end();
}

#[test]
/// Rescheduling a pending key under a full cap replaces its admission and restarts its notice;
/// revoking a key frees its slot.
fun a_full_cap_reschedules_a_pending_key_and_revocation_frees_a_slot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.fill_creator_claim_signers();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.clock.set_for_testing(3 * NOTICE_MS);
        f.schedule_creator_claim_signer(third_signer_public_key());

        let (_, _, _, _, ready_at_ms) = scheduled_one().set_scheduled_fields();
        assert_eq!(ready_at_ms, 4 * NOTICE_MS);
        let (_, _, change, _, cancelled_ready_at_ms) = cancelled_one_signer().set_cancelled_fields();
        assert_eq!(change.member(), option::some(third_signer_public_key()));
        assert_eq!(cancelled_ready_at_ms, 3 * NOTICE_MS);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.revoke_creator_claim_signer(signer_public_key());
        f.schedule_creator_claim_signer(fifth_signer_public_key());

        assert_eq!(f.config.creator_claim_signers(), vector[second_signer_public_key()]);
    });

    fixture.end();
}

#[test]
/// CancelAdmin discards a pending admission, even a ready one, so it never admits.
fun cancel_admin_cancels_a_ready_signer_key() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.clock.set_for_testing(NOTICE_MS);
        f.cancel_creator_claim_signer(signer_public_key());

        assert!(f.config.creator_claim_signers().is_empty());
        let (_, _, change, _, _) = cancelled_one_signer().set_cancelled_fields();
        assert_eq!(change.member(), option::some(signer_public_key()));
    });

    fixture.end();
}

#[test]
/// ClaimSignerAdmin proposes a notice that waits the applied one, anyone applies it, later
/// admissions wait it, and CancelAdmin discards a further proposal.
fun the_signer_notice_follows_its_own_lifecycle() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer_delay(NOTICE_MS / 2);

        let (_, _, change, delay_ms, ready_at_ms) = scheduled_one().set_scheduled_fields();
        assert!(change.member().is_none());
        assert_eq!(delay_ms, NOTICE_MS / 2);
        assert_eq!(ready_at_ms, NOTICE_MS);
    });

    fixture.next_tx!(ANYONE, |f| {
        f.clock.set_for_testing(NOTICE_MS);
        f.apply_creator_claim_signer_delay();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_creator_claim_signer(signer_public_key());
        let (_, _, _, _, ready_at_ms) = scheduled_one().set_scheduled_fields();
        assert_eq!(ready_at_ms, NOTICE_MS + NOTICE_MS / 2);

        f.schedule_creator_claim_signer_delay(NOTICE_MS);
        f.cancel_creator_claim_signer_delay();
        let (_, _, change, delay_ms, _) = cancelled_one_signer().set_cancelled_fields();
        assert!(change.member().is_none());
        assert_eq!(delay_ms, NOTICE_MS);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

/// Package initialization's events, and its shared configuration's signer keys and protocol share.
fun published_config(): (u64, vector<vector<u8>>, u64) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());

    let events = scenario.next_tx(PUBLISHER).num_user_events();
    let config = scenario.take_shared<RuntimeConfig>();
    let signer_public_keys = config.creator_claim_signers();
    let protocol_fee_share_bps = config.protocol_fee_share().value();
    test_scenario::return_shared(config);
    scenario.end();

    (events, signer_public_keys, protocol_fee_share_bps)
}

/// Bootstraps the published configuration in one transaction at `now_ms`: admits
/// `signer_public_key()` at the zero publication notice, raises the notice to `NOTICE_MS`, then
/// schedules `second_signer_public_key()`. Returns the admitted keys and that last admission.
fun bootstrapped_signers(now_ms: u64): (vector<vector<u8>>, SetScheduled<ClaimSignerKey, vector<u8>>) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());
    let package_version = package_version::version_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now_ms);

    scenario.next_tx(PUBLISHER);
    let mut config = scenario.take_shared<RuntimeConfig>();
    config.schedule_creator_claim_signer(&package_version, &claim_signer_admin(), signer_public_key(), &clock);
    config.apply_creator_claim_signer(&package_version, signer_public_key(), &clock);
    config.schedule_creator_claim_signer_delay(&package_version, &claim_signer_admin(), NOTICE_MS, &clock);
    config.apply_creator_claim_signer_delay(&package_version, &clock);
    config.schedule_creator_claim_signer(&package_version, &claim_signer_admin(), second_signer_public_key(), &clock);
    let signer_public_keys = config.creator_claim_signers();
    let second_admission = scheduled_signers().pop_back();

    config.cancel_creator_claim_signer(&package_version, &cancel_admin(), second_signer_public_key());
    test_scenario::return_shared(config);
    destroy(package_version);
    destroy(clock);
    scenario.end();

    (signer_public_keys, second_admission)
}

/// A configuration with no claim signer and the signer notice raised to `NOTICE_MS`, at time zero.
fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::version_for_testing(scenario.ctx());
    let config = runtime_config::new_zero_fee_share_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    ConfigFixture { scenario, package_version, config, clock }
}

fun config_set_protocol_fee_share(self: &mut ConfigFixture, protocol_fee_share_bps: Bps) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self
        .config
        .set_protocol_fee_share_for_testing(
            &self.package_version,
            &admin_witness,
            protocol_fee_share_bps,
            self.scenario.ctx()
        );
}

fun config_schedule_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    self
        .config
        .schedule_creator_claim_signer(&self.package_version, &claim_signer_admin(), signer_public_key, &self.clock);
}

/// Applies without any administrator witness.
fun config_apply_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    self.config.apply_creator_claim_signer(&self.package_version, signer_public_key, &self.clock);
}

fun config_cancel_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    self.config.cancel_creator_claim_signer(&self.package_version, &cancel_admin(), signer_public_key);
}

fun config_revoke_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    self.config.revoke_creator_claim_signer(&self.package_version, &claim_signer_admin(), signer_public_key);
}

fun config_schedule_creator_claim_signer_delay(self: &mut ConfigFixture, delay_ms: u64) {
    self
        .config
        .schedule_creator_claim_signer_delay(&self.package_version, &claim_signer_admin(), delay_ms, &self.clock);
}

/// Applies without any administrator witness.
fun config_apply_creator_claim_signer_delay(self: &mut ConfigFixture) {
    self.config.apply_creator_claim_signer_delay(&self.package_version, &self.clock);
}

fun config_cancel_creator_claim_signer_delay(self: &mut ConfigFixture) {
    self.config.cancel_creator_claim_signer_delay(&self.package_version, &cancel_admin());
}

/// Schedules `signer_public_key`, waits the notice on the fixture clock, and admits it.
fun config_admit_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    self.schedule_creator_claim_signer(signer_public_key);
    let ready_at_ms = self.clock.timestamp_ms() + NOTICE_MS;
    self.clock.set_for_testing(ready_at_ms);
    self.apply_creator_claim_signer(signer_public_key);
}

/// Two live keys and two pending ones, the third scheduled at `2 * NOTICE_MS`: the cap is full.
fun config_fill_creator_claim_signers(self: &mut ConfigFixture) {
    self.admit_creator_claim_signer(signer_public_key());
    self.admit_creator_claim_signer(second_signer_public_key());
    self.schedule_creator_claim_signer(third_signer_public_key());
    self.schedule_creator_claim_signer(fourth_signer_public_key());
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

fun claim_signer_admin(): AdminWitness<ClaimSignerAdmin> {
    blast_acl::witness_for_testing<ClaimSignerAdmin>()
}

fun cancel_admin(): AdminWitness<CancelAdmin> {
    blast_acl::witness_for_testing<CancelAdmin>()
}

fun signer_public_key(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun second_signer_public_key(): vector<u8> {
    x"2222222222222222222222222222222222222222222222222222222222222222"
}

fun third_signer_public_key(): vector<u8> {
    x"3333333333333333333333333333333333333333333333333333333333333333"
}

fun fourth_signer_public_key(): vector<u8> {
    x"4444444444444444444444444444444444444444444444444444444444444444"
}

fun fifth_signer_public_key(): vector<u8> {
    x"5555555555555555555555555555555555555555555555555555555555555555"
}

/// The signer set's admission and notice proposals in this transaction, in order.
fun scheduled_signers(): vector<SetScheduled<ClaimSignerKey, vector<u8>>> {
    event::events_by_type<SetScheduled<ClaimSignerKey, vector<u8>>>()
}

fun scheduled_one(): SetScheduled<ClaimSignerKey, vector<u8>> {
    let mut scheduled = scheduled_signers();
    assert_eq!(scheduled.length(), 1);
    scheduled.pop_back()
}

fun applied_one_signer(): SetApplied<ClaimSignerKey, vector<u8>> {
    let mut applied = event::events_by_type<SetApplied<ClaimSignerKey, vector<u8>>>();
    assert_eq!(applied.length(), 1);
    applied.pop_back()
}

fun cancelled_one_signer(): SetCancelled<ClaimSignerKey, vector<u8>> {
    let mut cancelled = event::events_by_type<SetCancelled<ClaimSignerKey, vector<u8>>>();
    assert_eq!(cancelled.length(), 1);
    cancelled.pop_back()
}

/// The values the primitive applied to the setting keyed by `K`, in order.
fun applied<K: copy + drop + store, T: copy + drop + store>(): vector<T> {
    event::events_by_type<DelayedApplied<K, T>>().map!(|applied| {
        let (_, _, _, value, _) = applied.delayed_applied_fields();
        value
    })
}

fun applied_one<K: copy + drop + store, T: copy + drop + store>(): T {
    let mut values = applied<K, T>();
    assert_eq!(values.length(), 1);
    values.pop_back()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    delayed::DelayedApplied,
    delayed_set::{MemberRemoved, SetApplied, SetCancelled, SetScheduled},
    package_version::PackageVersion
};

use blast_core::{blast_domain::{CancelAdmin, ClaimSignerAdmin, FeeAdmin}, bps::{Self, Bps}};

use blast_fun::{
    blast_fun::{Self as package_version, BLAST_FUN},
    runtime_config::{Self, ClaimSignerKey, ProtocolFeeShareKey, RuntimeConfig},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

use fun config_admit_creator_claim_signer as ConfigFixture.admit_creator_claim_signer;

use fun config_apply_creator_claim_signer as ConfigFixture.apply_creator_claim_signer;

use fun config_apply_creator_claim_signer_delay as ConfigFixture.apply_creator_claim_signer_delay;

use fun config_cancel_creator_claim_signer as ConfigFixture.cancel_creator_claim_signer;

use fun config_cancel_creator_claim_signer_delay as ConfigFixture.cancel_creator_claim_signer_delay;

use fun config_end as ConfigFixture.end;

use fun config_fill_creator_claim_signers as ConfigFixture.fill_creator_claim_signers;

use fun config_next_tx as ConfigFixture.next_tx;

use fun config_revoke_creator_claim_signer as ConfigFixture.revoke_creator_claim_signer;

use fun config_schedule_creator_claim_signer as ConfigFixture.schedule_creator_claim_signer;

use fun config_schedule_creator_claim_signer_delay as ConfigFixture.schedule_creator_claim_signer_delay;

use fun config_set_protocol_fee_share as ConfigFixture.set_protocol_fee_share_for_testing;
