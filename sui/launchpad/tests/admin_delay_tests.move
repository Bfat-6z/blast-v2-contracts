// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::admin_delay_tests;

// === Test-Only Types ===

public struct AdapterWitness has drop {}

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
    let scheduled = sui::event::events_by_type<blast_fun::blast_events::Event<blast_fun::events::TreasuryScheduled>>();
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
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
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
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
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
#[expected_failure(abort_code = blast_fun::errors::EWrongUpgradeAction, location = blast_fun::package_admin)]
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
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
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

#[test]
fun runtime_schedules_and_cancellations_preserve_every_proposed_value() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_disabled_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    let key = vector::tabulate!(32, |index| index as u8);

    config.schedule_creator_claim_signer(&version, &blast_acl::witness_for_testing<ClaimSignerAdmin>(), key, &clock);
    let key_bytes = std::bcs::to_bytes(&key);
    assert_eq!(event_bytes<events::CreatorClaimSignerScheduled>(), with_ready_at(key_bytes));
    config.cancel_creator_claim_signer(&version, &cancel);
    assert_eq!(event_bytes<events::CreatorClaimSignerCancelled>(), key_bytes);

    config.schedule_protocol_fee_share(&version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(123), &clock);
    let fee_bytes = u64_fields(vector[123]);
    assert_eq!(event_bytes<events::ProtocolFeeShareScheduled>(), with_ready_at(fee_bytes));
    config.cancel_protocol_fee_share(&version, &cancel);
    assert_eq!(event_bytes<events::ProtocolFeeShareCancelled>(), fee_bytes);

    let treasury = @0x123;
    config.schedule_treasury(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), treasury, &clock);
    let treasury_bytes = std::bcs::to_bytes(&treasury);
    assert_eq!(event_bytes<events::TreasuryScheduled>(), with_ready_at(treasury_bytes));
    config.cancel_treasury(&version, &cancel);
    assert_eq!(event_bytes<events::TreasuryCancelled>(), treasury_bytes);

    destroy(config);
    destroy(version);
    destroy(clock);
}

#[test]
fun launch_policy_schedules_and_cancellations_preserve_every_proposed_value() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = launch_config::new_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    let fee_admin = blast_acl::witness_for_testing<FeeAdmin>();

    config.schedule_protocol_allocation(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), bps::new(333), bps::new(444), &clock);
    let allocation_bytes = u64_fields(vector[333, 444]);
    assert_eq!(event_bytes<events::ProtocolAllocationScheduled>(), with_ready_at(allocation_bytes));
    config.cancel_protocol_allocation(&version, &cancel);
    assert_eq!(event_bytes<events::ProtocolAllocationCancelled>(), allocation_bytes);

    config.schedule_trade_fees(&version, &fee_admin, bps::new(111), bps::new(222), &clock);
    let fees_bytes = u64_fields(vector[111, 222]);
    assert_eq!(event_bytes<events::TradeFeesScheduled>(), with_ready_at(fees_bytes));
    config.cancel_trade_fees(&version, &cancel);
    assert_eq!(event_bytes<events::TradeFeesCancelled>(), fees_bytes);

    config.schedule_creation_fee(&version, &fee_admin, 123, &clock);
    let creation_fee_bytes = u64_fields(vector[123]);
    assert_eq!(event_bytes<events::CreationFeeScheduled>(), with_ready_at(creation_fee_bytes));
    config.cancel_creation_fee(&version, &cancel);
    assert_eq!(event_bytes<events::CreationFeeCancelled>(), creation_fee_bytes);

    config.schedule_migration_witness<AdapterWitness>(&version, &blast_acl::witness_for_testing<AdapterAdmin>(), &clock);
    let witness = std::type_name::with_original_ids<AdapterWitness>();
    let witness_bytes = std::bcs::to_bytes(&witness);
    assert_eq!(event_bytes<events::MigrationWitnessScheduled>(), with_ready_at(witness_bytes));
    config.cancel_migration_witness<AdapterWitness>(&version, &cancel);
    assert_eq!(event_bytes<events::MigrationWitnessCancelled>(), witness_bytes);

    destroy(config);
    destroy(version);
    destroy(clock);
}

#[test]
fun upgrade_schedule_and_cancellation_preserve_the_exact_digest() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let digest = vector::tabulate!(32, |index| index as u8);
    let mut action_bytes = vector[0u8];
    action_bytes.append(std::bcs::to_bytes(&digest));

    admin.schedule_upgrade(&version, &blast_acl::witness_for_testing<UpgradeAdmin>(), digest, &clock);
    assert_eq!(event_bytes<events::UpgradeActionScheduled>(), with_ready_at(action_bytes));
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    assert_eq!(event_bytes<events::UpgradeActionCancelled>(), action_bytes);

    destroy(admin);
    destroy(version);
    destroy(clock);
}

#[test]
fun immutability_schedule_and_cancellation_preserve_the_action() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let action_bytes = vector[1u8];

    admin.schedule_make_immutable(&version, &blast_acl::witness_for_testing<UpgradeAdmin>(), &clock);
    assert_eq!(event_bytes<events::UpgradeActionScheduled>(), with_ready_at(action_bytes));
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    assert_eq!(event_bytes<events::UpgradeActionCancelled>(), action_bytes);

    destroy(admin);
    destroy(version);
    destroy(clock);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::ENoPendingAction, location = blast_fun::package_admin)]
fun cancellation_without_a_scheduled_upgrade_reports_the_registry_error() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    abort
}

// === Test Helpers ===

fun event_bytes<T: copy + drop>(): vector<u8> {
    let events = sui::event::events_by_type<blast_fun::blast_events::Event<T>>();
    assert_eq!(events.length(), 1);
    std::bcs::to_bytes(&events[0])
}

fun u64_fields(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|value| bytes.append(std::bcs::to_bytes(&value)));
    bytes
}

fun with_ready_at(mut bytes: vector<u8>): vector<u8> {
    bytes.append(u64_fields(vector[172_800_123]));
    bytes
}

// === Imports ===

use blast_admin::blast_acl;
use blast_fun::{blast_fun as marker, blast_fun_domain::{AdapterAdmin, CancelAdmin, ClaimSignerAdmin, FeeAdmin, TreasuryAdmin, UpgradeAdmin}, bps, events, launch_config, runtime_config, package_admin};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
