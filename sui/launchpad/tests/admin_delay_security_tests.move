// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::admin_delay_security_tests;

// === Constants ===

const START: u64 = 1_234;
const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public enum Setting has copy, drop, store {
    ProtocolShare,
    Treasury,
    TradeFees,
    Allocation,
    LpFees,
    CreationFee,
}

public enum Case has copy, drop {
    Early,
    Replacement,
    Cancelled,
    Replay,
    StaleSchedule,
    StaleApply,
    StaleCancel,
    Success,
}

public struct Fixture {
    version: PackageVersion,
    clock: Clock,
    runtime: RuntimeConfig,
    config: LaunchConfig,
}

public struct CoinA has drop {}
public struct CoinB has drop {}

// === Tests ===

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun protocol_share_early() { exercise(Setting::ProtocolShare, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun protocol_share_replacement_restarts_notice() { exercise(Setting::ProtocolShare, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun protocol_share_cancelled() { exercise(Setting::ProtocolShare, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun protocol_share_replay() { exercise(Setting::ProtocolShare, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun protocol_share_stale_schedule() { exercise(Setting::ProtocolShare, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun protocol_share_stale_apply() { exercise(Setting::ProtocolShare, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun protocol_share_stale_cancel() { exercise(Setting::ProtocolShare, Case::StaleCancel); }

#[test]
fun protocol_share_boundaries_and_cancel_reschedule() { exercise(Setting::ProtocolShare, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun treasury_early() { exercise(Setting::Treasury, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun treasury_replacement_restarts_notice() { exercise(Setting::Treasury, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun treasury_cancelled() { exercise(Setting::Treasury, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun treasury_replay() { exercise(Setting::Treasury, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun treasury_stale_schedule() { exercise(Setting::Treasury, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun treasury_stale_apply() { exercise(Setting::Treasury, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun treasury_stale_cancel() { exercise(Setting::Treasury, Case::StaleCancel); }

#[test]
fun treasury_boundaries_and_cancel_reschedule() { exercise(Setting::Treasury, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun trade_fees_early() { exercise(Setting::TradeFees, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun trade_fees_replacement_restarts_notice() { exercise(Setting::TradeFees, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun trade_fees_cancelled() { exercise(Setting::TradeFees, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun trade_fees_replay() { exercise(Setting::TradeFees, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun trade_fees_stale_schedule() { exercise(Setting::TradeFees, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun trade_fees_stale_apply() { exercise(Setting::TradeFees, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun trade_fees_stale_cancel() { exercise(Setting::TradeFees, Case::StaleCancel); }

#[test]
fun trade_fees_boundaries_and_cancel_reschedule() { exercise(Setting::TradeFees, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun allocation_early() { exercise(Setting::Allocation, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun allocation_replacement_restarts_notice() { exercise(Setting::Allocation, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun allocation_cancelled() { exercise(Setting::Allocation, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun allocation_replay() { exercise(Setting::Allocation, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun allocation_stale_schedule() { exercise(Setting::Allocation, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun allocation_stale_apply() { exercise(Setting::Allocation, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun allocation_stale_cancel() { exercise(Setting::Allocation, Case::StaleCancel); }

#[test]
fun allocation_boundaries_and_cancel_reschedule() { exercise(Setting::Allocation, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun lp_fees_early() { exercise(Setting::LpFees, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun lp_fees_replacement_restarts_notice() { exercise(Setting::LpFees, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun lp_fees_cancelled() { exercise(Setting::LpFees, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun lp_fees_replay() { exercise(Setting::LpFees, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun lp_fees_stale_schedule() { exercise(Setting::LpFees, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun lp_fees_stale_apply() { exercise(Setting::LpFees, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun lp_fees_stale_cancel() { exercise(Setting::LpFees, Case::StaleCancel); }

#[test]
fun lp_fees_boundaries_and_cancel_reschedule() { exercise(Setting::LpFees, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun creation_fee_early() { exercise(Setting::CreationFee, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun creation_fee_replacement_restarts_notice() { exercise(Setting::CreationFee, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun creation_fee_cancelled() { exercise(Setting::CreationFee, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun creation_fee_replay() { exercise(Setting::CreationFee, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun creation_fee_stale_schedule() { exercise(Setting::CreationFee, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun creation_fee_stale_apply() { exercise(Setting::CreationFee, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun creation_fee_stale_cancel() { exercise(Setting::CreationFee, Case::StaleCancel); }

#[test]
fun creation_fee_boundaries_and_cancel_reschedule() { exercise(Setting::CreationFee, Case::Success); }

// === Test Helpers ===

/// Tests use a nonzero start so absolute timestamps cannot accidentally satisfy the delay.
fun exercise(setting: Setting, case: Case) {
    let mut f = start(setting);
    let initial = snapshot(&f, setting);
    if (case == Case::StaleSchedule) f.version.set_for_testing(2);
    schedule(&mut f, setting, 100);
    assert_notice(&f, setting, 100, true);
    assert_eq!(snapshot(&f, setting), initial);
    f.clock.set_for_testing(START + DELAY - if (case == Case::Early) 1 else 0);
    assert_eq!(snapshot(&f, setting), initial);
    match (case) {
        Case::Early => {
            apply(&mut f, setting);
            destroy(f);
        },
        Case::Replacement => {
            schedule(&mut f, setting, 200);
            assert_notice(&f, setting, 200, true);
            f.clock.set_for_testing(START + 2 * DELAY - 1);
            apply(&mut f, setting);
            destroy(f);
        },
        Case::Cancelled => {
            cancel(&mut f, setting);
            assert_notice(&f, setting, 100, false);
            assert_eq!(snapshot(&f, setting), initial);
            apply(&mut f, setting);
            destroy(f);
        },
        Case::Replay => {
            apply(&mut f, setting);
            apply(&mut f, setting);
            destroy(f);
        },
        Case::StaleSchedule => destroy(f),
        Case::StaleApply => {
            f.version.set_for_testing(2);
            apply(&mut f, setting);
            destroy(f);
        },
        Case::StaleCancel => {
            f.version.set_for_testing(2);
            cancel(&mut f, setting);
            assert_notice(&f, setting, 100, false);
            destroy(f);
        },
        Case::Success => {
            // A ready proposal can still be cancelled; a later proposal receives a full delay.
            cancel(&mut f, setting);
            assert_notice(&f, setting, 100, false);
            assert_eq!(snapshot(&f, setting), initial);
            schedule(&mut f, setting, 100);
            assert_notice(&f, setting, 100, true);
            f.clock.set_for_testing(START + 2 * DELAY);
            apply(&mut f, setting);
            assert_value(&f, setting, 100);
            // Replacement of a ready action keeps the applied value until explicit application.
            prepare_again(&mut f, setting);
            schedule(&mut f, setting, 200);
            assert_notice(&f, setting, 200, true);
            f.clock.set_for_testing(START + 4 * DELAY);
            schedule(&mut f, setting, 300);
            assert_notice(&f, setting, 300, true);
            let before = snapshot(&f, setting);
            f.clock.set_for_testing(START + 5 * DELAY + 1);
            assert_eq!(snapshot(&f, setting), before);
            apply(&mut f, setting);
            assert_value(&f, setting, 300);
            destroy(f);
        },
    };
}

fun start(setting: Setting): Fixture {
    let mut ctx = sui::tx_context::dummy();
    let version = package_version::new_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(START);
    let _ = setting;
    Fixture {
        version,
        clock,
        runtime: runtime_config::new_zero_fee_share_for_testing(&mut ctx),
        config: launch_config::new_zero_fees_for_testing(&mut ctx)
    }
}

fun prepare_again(f: &mut Fixture, setting: Setting) {
    let _ = f;
    let _ = setting;
}

fun schedule(f: &mut Fixture, setting: Setting, n: u64) {
    match (setting) {
        Setting::ProtocolShare => {
            f
                .runtime
                .schedule_protocol_fee_share(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    bps::new(n),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::Treasury => {
            f
                .runtime
                .schedule_treasury(
                    &f.version,
                    &blast_acl::witness_for_testing<TreasuryAdmin>(),
                    if (n == 100) @0x100
                    else if (n == 200) @0x200
                    else @0x300,
                    172_800_000,
                    &f.clock
                );
        },
        Setting::TradeFees => {
            f
                .config
                .schedule_trade_fees(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    bps::new(n),
                    bps::new(n + 1),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::Allocation => {
            f
                .config
                .schedule_protocol_allocation(
                    &f.version,
                    &blast_acl::witness_for_testing<TreasuryAdmin>(),
                    bps::new(n),
                    bps::new(n + 1),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::LpFees => {
            f
                .config
                .schedule_protocol_lp_fees(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    bps::new(n),
                    bps::new(n + 1),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::CreationFee => {
            f
                .config
                .schedule_creation_fee(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    n,
                    172_800_000,
                    &f.clock
                );
        },
    }
}

fun apply(f: &mut Fixture, setting: Setting) {
    match (setting) {

        Setting::ProtocolShare => { f.runtime.apply_protocol_fee_share(&f.version, &f.clock); },
        Setting::Treasury => { f.runtime.apply_treasury(&f.version, &f.clock); },
        Setting::TradeFees => { f.config.apply_trade_fees(&f.version, &f.clock); },
        Setting::Allocation => { f.config.apply_protocol_allocation(&f.version, &f.clock); },
        Setting::LpFees => { f.config.apply_protocol_lp_fees(&f.version, &f.clock); },
        Setting::CreationFee => { f.config.apply_creation_fee(&f.version, &f.clock); },
    }
}

fun cancel(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::ProtocolShare => {
            f
                .runtime
                .cancel_protocol_fee_share(
                    &f.version,
                    &blast_acl::witness_for_testing<CancelAdmin>()
                );
        },
        Setting::Treasury => {
            f.runtime.cancel_treasury(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
        Setting::TradeFees => {
            f.config.cancel_trade_fees(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
        Setting::Allocation => {
            f
                .config
                .cancel_protocol_allocation(
                    &f.version,
                    &blast_acl::witness_for_testing<CancelAdmin>()
                );
        },
        Setting::LpFees => {
            f
                .config
                .cancel_protocol_lp_fees(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
        Setting::CreationFee => {
            f
                .config
                .cancel_creation_fee(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
    }
}

fun snapshot(f: &Fixture, setting: Setting): vector<u8> {
    match (setting) {
        Setting::ProtocolShare => { bcs::to_bytes(&f.runtime.protocol_fee_share().value()) },
        Setting::Treasury => { bcs::to_bytes(&f.runtime.treasury()) },
        Setting::TradeFees => {
            let (a, b) = f.config.rate_defaults_for_testing();
            bcs::to_bytes(&vector[a, b])
        },
        Setting::Allocation => {
            let a = f.config.protocol_allocation();
            bcs::to_bytes(&vector[a.meme_bps().value(), a.quote_bps().value()])
        },
        Setting::LpFees => {
            let (meme_bps, quote_bps) = f.config.protocol_lp_fees();
            bcs::to_bytes(&vector[meme_bps.value(), quote_bps.value()])
        },
        Setting::CreationFee => { bcs::to_bytes(&f.config.creation_fee()) },
    }
}

fun expected(setting: Setting, n: u64): vector<u8> {
    match (setting) {

        Setting::ProtocolShare => { bcs::to_bytes(&n) },
        Setting::Treasury => { bcs::to_bytes(&(if (n == 100) @0x100 else if (n == 200) @0x200 else @0x300)) },
        Setting::TradeFees => { bcs::to_bytes(&vector[n, n + 1]) },
        Setting::Allocation => { bcs::to_bytes(&vector[n, n + 1]) },
        Setting::LpFees => { bcs::to_bytes(&vector[n, n + 1]) },
        Setting::CreationFee => { bcs::to_bytes(&n) },
    }
}

fun assert_value(f: &Fixture, setting: Setting, n: u64) { assert_eq!(snapshot(f, setting), expected(setting, n)); }

fun assert_notice(f: &Fixture, setting: Setting, n: u64, scheduled: bool) {
    let mut expected = match (setting) {
        Setting::ProtocolShare => { expected(setting, n) },
        Setting::Treasury => { expected(setting, n) },
        Setting::TradeFees => { u64_fields_bytes(vector[n, n + 1]) },
        Setting::Allocation => { u64_fields_bytes(vector[n, n + 1]) },
        Setting::LpFees => { u64_fields_bytes(vector[n, n + 1]) },
        Setting::CreationFee => { expected(setting, n) },
    };
    if (scheduled) {
        expected.append(bcs::to_bytes(&(f.clock.timestamp_ms() + DELAY)));
        let delay_ms = DELAY;
        expected.append(bcs::to_bytes(&delay_ms));
    };
    let actual = match (setting) {
        Setting::ProtocolShare => if (scheduled) last_scheduled<ProtocolFeeShareKey, Bps>()
        else last_cancelled<ProtocolFeeShareKey, Bps>(),
        Setting::Treasury => if (scheduled) last_scheduled<TreasuryKey, address>()
        else last_cancelled<TreasuryKey, address>(),
        Setting::TradeFees => if (scheduled) last_scheduled<TradeFeesKey, TradeFees>()
        else last_cancelled<TradeFeesKey, TradeFees>(),
        Setting::Allocation => if (scheduled) last_scheduled<ProtocolAllocationKey, ProtocolAllocation>()
        else last_cancelled<ProtocolAllocationKey, ProtocolAllocation>(),
        Setting::LpFees => if (scheduled) last_scheduled<ProtocolLpFeesKey, ProtocolLpFees>()
        else last_cancelled<ProtocolLpFeesKey, ProtocolLpFees>(),
        Setting::CreationFee => if (scheduled) last_scheduled<CreationFeeKey, u64>()
        else last_cancelled<CreationFeeKey, u64>(),
    };
    assert_eq!(actual, expected);
}

fun u64_fields_bytes(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|v| bytes.append(bcs::to_bytes(&v)));
    bytes
}

/// The latest proposal's value, deadline and next notice, in the retired payload's order.
fun last_scheduled<K: copy + drop + store, T: copy + drop + store>(): vector<u8> {
    let mut events = sui::event::events_by_type<DelayedScheduled<K, T>>();
    let (_, _, value, delay_ms, ready_at_ms) = events.pop_back().delayed_scheduled_fields();
    let mut bytes = bcs::to_bytes(&value);
    bytes.append(bcs::to_bytes(&ready_at_ms));
    bytes.append(bcs::to_bytes(&delay_ms));
    bytes
}

fun last_cancelled<K: copy + drop + store, T: copy + drop + store>(): vector<u8> {
    let mut events = sui::event::events_by_type<DelayedCancelled<K, T>>();
    let (_, _, value, _, _) = events.pop_back().delayed_cancelled_fields();
    bcs::to_bytes(&value)
}

// === Imports ===

use blast_core::bps::{Self, Bps};

use blast_fun::{
    allocation::ProtocolAllocation,
    blast_fun::{Self as package_version, PackageVersion},
    blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin},
    launch_config::{
        Self,
        CreationFeeKey,
        LaunchConfig,
        ProtocolAllocationKey,
        ProtocolLpFees,
        ProtocolLpFeesKey,
        TradeFees,
        TradeFeesKey,
    },
    runtime_config::{Self, ProtocolFeeShareKey, RuntimeConfig, TreasuryKey},
};

use blast_admin::{blast_acl, delayed::{DelayedCancelled, DelayedScheduled}};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::clock::Clock;
