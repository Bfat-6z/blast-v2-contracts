// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::admin_delay_tests;

// === Test-Only Types ===

public struct TestVenue has drop {}

// === Tests ===

#[test]
fun launch_policy_schedules_and_cancellations_preserve_every_proposed_value() {
    let mut ctx = tx_context::dummy();
    let version = otw::version_for_testing(&mut ctx);
    let mut config = launch_config::new_zero_fees_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(123);
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    let fee_admin = blast_acl::witness_for_testing<FeeAdmin>();

    let parent = object::id(&config);

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
    let (scheduled_parent, _, value, _, ready_at_ms) = scheduled.delayed_scheduled_fields();
    assert_eq!(scheduled_parent, parent);
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
    let (scheduled_parent, _, value, _, ready_at_ms) = single<DelayedScheduled<TradeFeesKey, TradeFees>>()
        .delayed_scheduled_fields();
    assert_eq!(scheduled_parent, parent);
    assert_eq!(std::bcs::to_bytes(&value), fees_bytes);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_trade_fees(&version, &cancel);
    let (_, _, value, _, _) = single<DelayedCancelled<TradeFeesKey, TradeFees>>()
        .delayed_cancelled_fields();
    assert_eq!(std::bcs::to_bytes(&value), fees_bytes);

    config.schedule_protocol_lp_fees(
        &version,
        &fee_admin,
        bps::new(1_200),
        bps::new(900),
        172_800_000,
        &clock
    );
    let lp_fees_bytes = u64_fields(vector[1_200, 900]);
    let (scheduled_parent, _, value, _, ready_at_ms) = single<
        DelayedScheduled<ProtocolLpFeesKey, ProtocolLpFees>
    >().delayed_scheduled_fields();
    assert_eq!(scheduled_parent, parent);
    assert_eq!(std::bcs::to_bytes(&value), lp_fees_bytes);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_protocol_lp_fees(&version, &cancel);
    let (_, _, value, _, _) = single<DelayedCancelled<ProtocolLpFeesKey, ProtocolLpFees>>()
        .delayed_cancelled_fields();
    assert_eq!(std::bcs::to_bytes(&value), lp_fees_bytes);

    config.schedule_creation_fee(&version, &fee_admin, 123, 172_800_000, &clock);
    let (scheduled_parent, _, value, _, ready_at_ms) = single<DelayedScheduled<CreationFeeKey, u64>>()
        .delayed_scheduled_fields();
    assert_eq!(scheduled_parent, parent);
    assert_eq!(value, 123);
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_creation_fee(&version, &cancel);
    let (_, _, value, _, _) = single<DelayedCancelled<CreationFeeKey, u64>>().delayed_cancelled_fields();
    assert_eq!(value, 123);

    config.schedule_venue<TestVenue>(
        &version,
        &blast_acl::witness_for_testing<VenueAdmin>(),
        &clock
    );
    let witness = std::type_name::with_original_ids<TestVenue>();
    let (scheduled_parent, _, change, _, ready_at_ms) = single<
        SetScheduled<VenueKey, TypeName>
    >().set_scheduled_fields();
    assert_eq!(scheduled_parent, parent);
    assert_eq!(change.member(), option::some(witness));
    assert_eq!(ready_at_ms, 172_800_123);
    config.cancel_venue<TestVenue>(&version, &cancel);
    let (_, _, change, _, _) = single<SetCancelled<VenueKey, TypeName>>()
        .set_cancelled_fields();
    assert_eq!(change.member(), option::some(witness));

    destroy(config);
    destroy(version);
    destroy(clock);
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
    delayed_set::{SetCancelled, SetScheduled}
};

use blast_core::{bps, blast_domain::{VenueAdmin, CancelAdmin, FeeAdmin, TreasuryAdmin}};

use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    blast_fun as otw,
    launch_config::{
        Self,
        CreationFeeKey,
        ProtocolAllocationKey,
        ProtocolLpFees,
        ProtocolLpFeesKey,
        TradeFees,
        TradeFeesKey,
        VenueKey,
    },
};
use std::{type_name::TypeName, unit_test::{assert_eq, destroy}};
use sui::clock;
