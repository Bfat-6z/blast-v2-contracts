// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::admin_delay_tests;

// === Tests ===

#[test]
fun treasury_changes_only_on_permissionless_apply_and_events_record_the_schedule() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_disabled_for_testing(&mut ctx);
    let original = config.treasury();
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), @0x123, &clock);
    assert_eq!(config.treasury(), original);
    let scheduled = sui::event::events_by_type<blast_fun::blast_events::Event<runtime_config::TreasuryScheduled>>();
    let mut expected = std::bcs::to_bytes(&@0x123);
    expected.append(std::bcs::to_bytes(&172_800_000u64));
    assert_eq!(std::bcs::to_bytes(&scheduled[0]), expected);
    clock.set_for_testing(172_800_000);
    assert_eq!(config.treasury(), original);
    config.apply_treasury(&version, &clock);
    assert_eq!(config.treasury(), @0x123);
    destroy(config);
    destroy(version);
    destroy(clock);
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun treasury_cannot_change_before_the_full_delay() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_disabled_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), @0x123, &clock);
    clock.set_for_testing(172_799_999);
    config.apply_treasury(&version, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::ENoPending, location = blast_admin::delayed)]
fun cancel_admin_can_stop_a_ready_treasury_change() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_disabled_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), @0x123, &clock);
    clock.set_for_testing(172_800_000);
    config.cancel_treasury(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    config.apply_treasury(&version, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = package_admin::EWrongUpgradeAction, location = blast_fun::package_admin)]
fun a_ready_digest_does_not_authorize_different_code() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    let mut clock = clock::create_for_testing(&mut ctx);
    admin.schedule_upgrade(&version, &witness, vector::tabulate!(32, |_| 1u8), &clock);
    clock.set_for_testing(172_800_000);
    let ticket = admin.authorize_upgrade(&version, &witness, vector::tabulate!(32, |_| 2u8), &clock);
    destroy(ticket);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun upgrade_authorization_cannot_be_issued_early() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    let clock = clock::create_for_testing(&mut ctx);
    let digest = vector::tabulate!(32, |_| 1u8);
    admin.schedule_upgrade(&version, &witness, digest, &clock);
    let ticket = admin.authorize_upgrade(&version, &witness, digest, &clock);
    destroy(ticket);
    abort
}

// === Imports ===

use blast_admin::{blast_acl, delayed};
use blast_fun::{blast_fun as marker, blast_fun_domain::{CancelAdmin, TreasuryAdmin, UpgradeAdmin}, runtime_config, package_admin};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
