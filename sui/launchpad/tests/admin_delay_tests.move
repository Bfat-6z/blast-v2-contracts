// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::admin_delay_tests;

// === Test-Only Types ===

public struct AdapterWitness has drop {}

// === Tests ===

#[test]
fun treasury_changes_only_on_permissionless_apply_and_the_primitive_records_the_schedule() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_zero_fee_share_for_testing(&mut ctx);
    let original = config.treasury();
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(
        &version,
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        @0x123,
        172_800_000,
        &clock
    );
    assert_eq!(config.treasury(), original);
    let (owner, key, value, delay_ms, ready_at_ms) = single<DelayedScheduled<TreasuryKey, address>>()
        .delayed_scheduled_fields();
    assert_eq!(owner, object::id(&config));
    // A zero-field key compiles with one `dummy_field: bool`; off-chain decoders read one byte.
    assert_eq!(std::bcs::to_bytes(&key), vector[0]);
    assert_eq!(value, @0x123);
    assert_eq!(delay_ms, 172_800_000);
    assert_eq!(ready_at_ms, 172_800_000);
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
    let mut config = runtime_config::new_zero_fee_share_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(
        &version,
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        @0x123,
        172_800_000,
        &clock
    );
    clock.set_for_testing(172_799_999);
    config.apply_treasury(&version, &clock);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun cancel_admin_can_stop_a_ready_treasury_change() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = runtime_config::new_zero_fee_share_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    config.schedule_treasury(
        &version,
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        @0x123,
        172_800_000,
        &clock
    );
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
    let ticket = admin.authorize_upgrade(
        &version,
        &witness,
        vector::tabulate!(32, |_| 2u8),
        &clock
    );
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
fun launch_policy_schedules_and_cancellations_preserve_every_proposed_value() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut config = launch_config::new_zero_fees_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    let fee_admin = blast_acl::witness_for_testing<FeeAdmin>();

    let owner = object::id(&config);

    config.schedule_protocol_allocation(
        &version,
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        bps::new(333),
        bps::new(444),
        172_800_000,
        &clock
    );
    let allocation = allocation::protocol_allocation(bps::new(333), bps::new(444));
    let scheduled = single<DelayedScheduled<ProtocolAllocationKey, ProtocolAllocation>>();
    let (scheduled_owner, _, value, _, ready_at_ms) = scheduled.delayed_scheduled_fields();
    assert_eq!(scheduled_owner, owner);
    assert_eq!(value, allocation);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_protocol_allocation(&version, &cancel);
    let cancelled = single<DelayedCancelled<ProtocolAllocationKey, ProtocolAllocation>>();
    let (_, _, value, _, _) = cancelled.delayed_cancelled_fields();
    assert_eq!(value, allocation);

    config.schedule_trade_fees(
        &version,
        &fee_admin,
        bps::new(111),
        bps::new(222),
        172_800_000,
        &clock
    );
    let fees_bytes = u64_fields(vector[111, 222]);
    let (scheduled_owner, _, value, _, ready_at_ms) = single<DelayedScheduled<TradeFeesKey, TradeFees>>()
        .delayed_scheduled_fields();
    assert_eq!(scheduled_owner, owner);
    assert_eq!(std::bcs::to_bytes(&value), fees_bytes);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_trade_fees(&version, &cancel);
    let (_, _, value, _, _) = single<DelayedCancelled<TradeFeesKey, TradeFees>>()
        .delayed_cancelled_fields();
    assert_eq!(std::bcs::to_bytes(&value), fees_bytes);

    config.schedule_creation_fee(&version, &fee_admin, 123, 172_800_000, &clock);
    let (scheduled_owner, _, value, _, ready_at_ms) = single<DelayedScheduled<CreationFeeKey, u64>>()
        .delayed_scheduled_fields();
    assert_eq!(scheduled_owner, owner);
    assert_eq!(value, 123);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_creation_fee(&version, &cancel);
    let (_, _, value, _, _) = single<DelayedCancelled<CreationFeeKey, u64>>().delayed_cancelled_fields();
    assert_eq!(value, 123);

    config.schedule_migration_witness<AdapterWitness>(
        &version,
        &blast_acl::witness_for_testing<AdapterAdmin>(),
        &clock
    );
    let witness = std::type_name::with_original_ids<AdapterWitness>();
    let (scheduled_owner, _, change, _, ready_at_ms) = single<
        SetScheduled<MigrationWitnessKey, TypeName>
    >().set_scheduled_fields();
    assert_eq!(scheduled_owner, owner);
    assert_eq!(change.member_for_testing(), option::some(witness));
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_migration_witness<AdapterWitness>(&version, &cancel);
    let (_, _, change, _, _) = single<SetCancelled<MigrationWitnessKey, TypeName>>()
        .set_cancelled_fields();
    assert_eq!(change.member_for_testing(), option::some(witness));

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
    let (owner, _, change, delay_ms, ready_at_ms) = single<ActionScheduled<UpgradeKey, UpgradeAction>>()
        .action_scheduled_fields();
    assert_eq!(owner, admin.id_for_testing());
    assert_eq!(std::bcs::to_bytes(&change.action().destroy_some()), action_bytes);
    assert_eq!(delay_ms, 172_800_000);
    assert_eq!(ready_at_ms, 172_800_123);
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    let (_, _, change, _, _) = single<ActionCancelled<UpgradeKey, UpgradeAction>>()
        .action_cancelled_fields();
    assert_eq!(std::bcs::to_bytes(&change.action().destroy_some()), action_bytes);

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
    let (_, _, change, _, ready_at_ms) = single<ActionScheduled<UpgradeKey, UpgradeAction>>()
        .action_scheduled_fields();
    assert_eq!(std::bcs::to_bytes(&change.action().destroy_some()), action_bytes);
    assert_eq!(ready_at_ms, 172_800_123);
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    let (_, _, change, _, _) = single<ActionCancelled<UpgradeKey, UpgradeAction>>()
        .action_cancelled_fields();
    assert_eq!(std::bcs::to_bytes(&change.action().destroy_some()), action_bytes);

    destroy(admin);
    destroy(version);
    destroy(clock);
}

#[test]
fun upgrade_delay_schedule_and_cancellation_preserve_the_notice_change() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);

    admin.schedule_upgrade_delay(&version, &blast_acl::witness_for_testing<UpgradeAdmin>(), 0, &clock);
    let (_, _, change, delay_ms, ready_at_ms) = single<ActionScheduled<UpgradeKey, UpgradeAction>>()
        .action_scheduled_fields();
    assert!(change.action().is_none());
    assert_eq!(delay_ms, 0);
    assert_eq!(ready_at_ms, 172_800_123);
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    let (_, _, change, delay_ms, _) = single<ActionCancelled<UpgradeKey, UpgradeAction>>()
        .action_cancelled_fields();
    assert!(change.action().is_none());
    assert_eq!(delay_ms, 0);
    assert_eq!(admin.upgrade_delay_ms(), 172_800_000);

    destroy(admin);
    destroy(version);
    destroy(clock);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun cancellation_without_a_scheduled_upgrade_reports_the_primitive_error() {
    let mut ctx = tx_context::dummy();
    let version = marker::new_for_testing(&mut ctx);
    let mut admin = package_admin::new_for_testing(&mut ctx);
    admin.cancel_upgrade_action(&version, &blast_acl::witness_for_testing<CancelAdmin>());
    abort
}

// === Test Helpers ===

fun single<T: copy + drop>(): T {
    let events = sui::event::events_by_type<T>();
    assert_eq!(events.length(), 1);
    events[0]
}

fun u64_fields(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|value| bytes.append(std::bcs::to_bytes(&value)));
    bytes
}

// === Imports ===

use blast_admin::{
    blast_acl,
    delayed::{DelayedCancelled, DelayedScheduled},
    delayed_action::{ActionCancelled, ActionScheduled},
    delayed_set::{SetCancelled, SetScheduled},
};
use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    blast_fun as marker,
    blast_fun_domain::{AdapterAdmin, CancelAdmin, FeeAdmin, TreasuryAdmin, UpgradeAdmin},
    bps,
    launch_config::{Self, CreationFeeKey, MigrationWitnessKey, ProtocolAllocationKey, TradeFees, TradeFeesKey},
    package_admin::{Self, UpgradeAction, UpgradeKey},
    runtime_config::{Self, TreasuryKey},
};
use std::{type_name::TypeName, unit_test::{assert_eq, destroy}};
use sui::clock;
