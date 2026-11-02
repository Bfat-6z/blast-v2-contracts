// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::admin_delay_security_tests;

// === Constants ===

const START: u64 = 1_234;
const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public enum Setting has copy, drop, store { Destination, Defaults, CoinOverride, CoinClear }

public enum Case has copy, drop { Early, Replacement, Cancelled, Replay, StaleSchedule, StaleApply, StaleCancel, Success }

public struct Fixture { version: PackageVersion, clock: Clock, policy: LpFeePolicy, }

public struct CoinA has drop {}
public struct CoinB has drop {}

// === Tests ===

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun destination_early() { exercise(Setting::Destination, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun destination_replacement_restarts_notice() { exercise(Setting::Destination, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun destination_cancelled() { exercise(Setting::Destination, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun destination_replay() { exercise(Setting::Destination, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun destination_stale_schedule() { exercise(Setting::Destination, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun destination_stale_apply() { exercise(Setting::Destination, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun destination_stale_cancel() { exercise(Setting::Destination, Case::StaleCancel); }

#[test]
fun destination_boundaries_and_cancel_reschedule() { exercise(Setting::Destination, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun defaults_early() { exercise(Setting::Defaults, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun defaults_replacement_restarts_notice() { exercise(Setting::Defaults, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun defaults_cancelled() { exercise(Setting::Defaults, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun defaults_replay() { exercise(Setting::Defaults, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun defaults_stale_schedule() { exercise(Setting::Defaults, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun defaults_stale_apply() { exercise(Setting::Defaults, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun defaults_stale_cancel() { exercise(Setting::Defaults, Case::StaleCancel); }

#[test]
fun defaults_boundaries_and_cancel_reschedule() { exercise(Setting::Defaults, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun coin_override_early() { exercise(Setting::CoinOverride, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun coin_override_replacement_restarts_notice() { exercise(Setting::CoinOverride, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun coin_override_cancelled() { exercise(Setting::CoinOverride, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun coin_override_replay() { exercise(Setting::CoinOverride, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_override_stale_schedule() { exercise(Setting::CoinOverride, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_override_stale_apply() { exercise(Setting::CoinOverride, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_override_stale_cancel() { exercise(Setting::CoinOverride, Case::StaleCancel); }

#[test]
fun coin_override_boundaries_and_cancel_reschedule() { exercise(Setting::CoinOverride, Case::Success); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun coin_clear_early() { exercise(Setting::CoinClear, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun coin_clear_replacement_restarts_notice() { exercise(Setting::CoinClear, Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun coin_clear_cancelled() { exercise(Setting::CoinClear, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun coin_clear_replay() { exercise(Setting::CoinClear, Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_clear_stale_schedule() { exercise(Setting::CoinClear, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_clear_stale_apply() { exercise(Setting::CoinClear, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun coin_clear_stale_cancel() { exercise(Setting::CoinClear, Case::StaleCancel); }

#[test]
fun coin_clear_boundaries_and_cancel_reschedule() { exercise(Setting::CoinClear, Case::Success); }

#[test]
fun coin_clear_uses_defaults_applied_during_its_notice() {
    let mut fixture = start(Setting::CoinClear);
    let f = &mut fixture;
    let fee_admin = blast_acl::witness_for_testing<FeeAdmin>();
    f.policy.schedule_clear_coin_shares<CoinA>(&f.version, &fee_admin, &f.clock);
    f.policy.schedule_default_shares(&f.version, &fee_admin, bps::new(900), bps::new(901), &f.clock);
    f.clock.set_for_testing(START + DELAY);
    f.policy.apply_default_shares(&f.version, &f.clock);
    let (a, b) = f.policy.shares<CoinA>();
    assert_eq!(vector[a.value(), b.value()], vector[5, 6]);
    f.policy.apply_coin_shares<CoinA>(&f.version, &f.clock);
    let (a, b) = f.policy.shares<CoinA>();
    let (other_a, other_b) = f.policy.shares<CoinB>();
    assert_eq!(vector[a.value(), b.value(), other_a.value(), other_b.value()], vector[900, 901, 7, 8]);
    destroy(fixture);
}

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
        Case::Early => { apply(&mut f, setting); destroy(f); },
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
        Case::Replay => { apply(&mut f, setting); apply(&mut f, setting); destroy(f); },
        Case::StaleSchedule => destroy(f),
        Case::StaleApply => { f.version.set_for_testing(2); apply(&mut f, setting); destroy(f); },
        Case::StaleCancel => { f.version.set_for_testing(2); cancel(&mut f, setting);
            assert_notice(&f, setting, 100, false); destroy(f); },
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
    let mut policy = lp_fee_policy::new_for_testing(&mut ctx);
    // Existing overrides must survive unrelated coin changes and cancellations.
    policy.set_coin_shares_for_testing<CoinA>(&version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(5), bps::new(6), &mut ctx);
    policy.set_coin_shares_for_testing<CoinB>(&version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(7), bps::new(8), &mut ctx);
    let _ = setting;
    Fixture { version, clock, policy }
}

fun prepare_again(f: &mut Fixture, setting: Setting) { if (setting == Setting::CoinClear) {
    f.policy.schedule_coin_shares<CoinA>(&f.version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(5), bps::new(6), &f.clock);
    f.clock.set_for_testing(START + 3 * DELAY);
    f.policy.apply_coin_shares<CoinA>(&f.version, &f.clock);
} }

fun schedule(f: &mut Fixture, setting: Setting, n: u64) {
    match (setting) {
        Setting::Destination => { f.policy.schedule_protocol_destination(&f.version, &blast_acl::witness_for_testing<TreasuryAdmin>(), if (n == 100) @0x100 else if (n == 200) @0x200 else @0x300, &f.clock); },
        Setting::Defaults => { f.policy.schedule_default_shares(&f.version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(n), bps::new(n + 1), &f.clock); },
        Setting::CoinOverride => { f.policy.schedule_coin_shares<CoinA>(&f.version, &blast_acl::witness_for_testing<FeeAdmin>(), bps::new(n), bps::new(n + 1), &f.clock); },
        Setting::CoinClear => { let _ = n; f.policy.schedule_clear_coin_shares<CoinA>(&f.version, &blast_acl::witness_for_testing<FeeAdmin>(), &f.clock); },
    }
}

fun apply(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::Destination => { f.policy.apply_protocol_destination(&f.version, &f.clock); },
        Setting::Defaults => { f.policy.apply_default_shares(&f.version, &f.clock); },
        Setting::CoinOverride => { f.policy.apply_coin_shares<CoinA>(&f.version, &f.clock); },
        Setting::CoinClear => { f.policy.apply_coin_shares<CoinA>(&f.version, &f.clock); },
    }
}

fun cancel(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::Destination => { f.policy.cancel_protocol_destination(&f.version, &blast_acl::witness_for_testing<CancelAdmin>()); },
        Setting::Defaults => { f.policy.cancel_default_shares(&f.version, &blast_acl::witness_for_testing<CancelAdmin>()); },
        Setting::CoinOverride => { f.policy.cancel_coin_shares<CoinA>(&f.version, &blast_acl::witness_for_testing<CancelAdmin>()); },
        Setting::CoinClear => { f.policy.cancel_coin_shares<CoinA>(&f.version, &blast_acl::witness_for_testing<CancelAdmin>()); },
    }
}

fun snapshot(f: &Fixture, setting: Setting): vector<u8> {
    match (setting) {
        Setting::Destination => { bcs::to_bytes(&f.policy.protocol_destination()) },
        Setting::Defaults => { let (a, b) = f.policy.default_shares_for_testing(); bcs::to_bytes(&vector[a.value(), b.value()]) },
        Setting::CoinOverride => { let (a, b) = f.policy.shares<CoinA>(); let (c, d) = f.policy.shares<CoinB>(); bcs::to_bytes(&vector[a.value(), b.value(), c.value(), d.value()]) },
        Setting::CoinClear => { let (a, b) = f.policy.shares<CoinA>(); let (c, d) = f.policy.shares<CoinB>(); bcs::to_bytes(&vector[a.value(), b.value(), c.value(), d.value()]) },
    }
}

fun expected(setting: Setting, n: u64): vector<u8> {
    match (setting) {
        Setting::Destination => { bcs::to_bytes(&(if (n == 100) @0x100 else if (n == 200) @0x200 else @0x300)) },
        Setting::Defaults => { bcs::to_bytes(&vector[n, n + 1]) },
        Setting::CoinOverride => { bcs::to_bytes(&vector[n, n + 1, 7, 8]) },
        Setting::CoinClear => { let _ = n; bcs::to_bytes(&vector[0u64, 0, 7, 8]) },
    }
}

fun assert_value(f: &Fixture, setting: Setting, n: u64) { assert_eq!(snapshot(f, setting), expected(setting, n)); }

fun assert_notice(f: &Fixture, setting: Setting, n: u64, scheduled: bool) {
    let mut expected = match (setting) {
        Setting::Destination => { expected(setting, n) },
        Setting::Defaults => { u64_fields_bytes(vector[n, n + 1]) },
        Setting::CoinOverride => { let mut bytes = bcs::to_bytes(&std::type_name::with_original_ids<CoinA>()); bytes.append(bcs::to_bytes(&option::some(n))); bytes.append(bcs::to_bytes(&option::some(n + 1))); bytes },
        Setting::CoinClear => { let mut bytes = bcs::to_bytes(&std::type_name::with_original_ids<CoinA>()); bytes.append(bcs::to_bytes(&option::none<u64>())); bytes.append(bcs::to_bytes(&option::none<u64>())); bytes },
    };
    if (scheduled) expected.append(bcs::to_bytes(&(f.clock.timestamp_ms() + DELAY)));
    let actual = match (setting) {
        Setting::Destination => if (scheduled) last_event<blast_events::ProtocolDestinationScheduled>() else last_event<blast_events::ProtocolDestinationCancelled>(),
        Setting::Defaults => if (scheduled) last_event<blast_events::DefaultSharesScheduled>() else last_event<blast_events::DefaultSharesCancelled>(),
        Setting::CoinOverride => if (scheduled) last_event<blast_events::CoinSharesScheduled>() else last_event<blast_events::CoinSharesCancelled>(),
        Setting::CoinClear => if (scheduled) last_event<blast_events::CoinSharesScheduled>() else last_event<blast_events::CoinSharesCancelled>(),
    };
    assert_eq!(actual, expected);
}

fun u64_fields_bytes(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|v| bytes.append(bcs::to_bytes(&v)));
    bytes
}

fun last_event<T: copy + drop>(): vector<u8> { let mut events = sui::event::events_by_type<T>(); bcs::to_bytes(&events.pop_back()) }

// === Imports ===

use blast_fun_migrators::{
    blast_events,
    blast_fun_migrators::{Self as package_version, PackageVersion}, lp_fee_policy::{Self, LpFeePolicy}
};


use blast_admin::blast_acl;
use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::clock::Clock;
