// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::admin_delay_security_tests;

// === Constants ===

const START: u64 = 1_234;
const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public enum Setting has copy, drop, store {
    Fees,
    Destination,
    VaultFees,
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
    policy: FeePolicy,
    vault: Vault<CoinA, CoinB>,
}

public struct CoinA has drop {}
public struct CoinB has drop {}

// === Tests ===

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun fees_early() { exercise(Setting::Fees, Case::Early); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun fees_replacement_restarts_notice() { exercise(Setting::Fees, Case::Replacement); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun fees_cancelled() { exercise(Setting::Fees, Case::Cancelled); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun fees_replay() { exercise(Setting::Fees, Case::Replay); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun fees_stale_schedule() { exercise(Setting::Fees, Case::StaleSchedule); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun fees_stale_apply() { exercise(Setting::Fees, Case::StaleApply); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun fees_stale_cancel() { exercise(Setting::Fees, Case::StaleCancel); }

#[test]
fun fees_boundaries_and_cancel_reschedule() { exercise(Setting::Fees, Case::Success); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun destination_early() { exercise(Setting::Destination, Case::Early); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun destination_replacement_restarts_notice() { exercise(Setting::Destination, Case::Replacement); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun destination_cancelled() { exercise(Setting::Destination, Case::Cancelled); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun destination_replay() { exercise(Setting::Destination, Case::Replay); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun destination_stale_schedule() { exercise(Setting::Destination, Case::StaleSchedule); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun destination_stale_apply() { exercise(Setting::Destination, Case::StaleApply); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun destination_stale_cancel() { exercise(Setting::Destination, Case::StaleCancel); }

#[test]
fun destination_boundaries_and_cancel_reschedule() { exercise(Setting::Destination, Case::Success); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun vault_fees_early() { exercise(Setting::VaultFees, Case::Early); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun vault_fees_replacement() { exercise(Setting::VaultFees, Case::Replacement); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun vault_fees_cancelled() { exercise(Setting::VaultFees, Case::Cancelled); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun vault_fees_replay() { exercise(Setting::VaultFees, Case::Replay); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun vault_fees_stale_schedule() { exercise(Setting::VaultFees, Case::StaleSchedule); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun vault_fees_stale_apply() { exercise(Setting::VaultFees, Case::StaleApply); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun vault_fees_stale_cancel() { exercise(Setting::VaultFees, Case::StaleCancel); }

#[test]
fun vault_fees_boundaries_and_cancel_reschedule() { exercise(Setting::VaultFees, Case::Success); }

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
    let vault = presale_vault::new_for_testing<CoinA, CoinB>(
        sui::object::id_from_address(@0xCAFE),
        sui::object::id_from_address(@0xCA9),
        blast_presale::blast_presale::fee_split(vector[], bps::new(10_000)),
        fee_policy::protocol_fees_for_testing(11, 12, 0, 0),
        option::none(),
        &mut ctx,
    );
    Fixture { version, clock, policy: fee_policy::new_zero_fees_for_testing(&mut ctx), vault }
}

fun prepare_again(f: &mut Fixture, setting: Setting) {
    let _ = f;
    let _ = setting;
}

fun schedule(f: &mut Fixture, setting: Setting, n: u64) {
    match (setting) {
        Setting::VaultFees => {
            f
                .vault
                .schedule_protocol_lp_fees(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    bps::new(n),
                    bps::new(n + 1),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::Fees => {
            f
                .policy
                .schedule_fees(
                    &f.version,
                    &blast_acl::witness_for_testing<FeeAdmin>(),
                    bps::new(n),
                    bps::new(n + 1),
                    bps::new(n + 2),
                    bps::new(n + 3),
                    172_800_000,
                    &f.clock
                );
        },
        Setting::Destination => {
            f
                .policy
                .schedule_destination(
                    &f.version,
                    &blast_acl::witness_for_testing<TreasuryAdmin>(),
                    if (n == 100) @0x100
                    else if (n == 200) @0x200
                    else @0x300,
                    172_800_000,
                    &f.clock
                );
        },
    }
}

fun apply(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::VaultFees => { f.vault.apply_protocol_lp_fees(&f.version, &f.clock); },
        Setting::Fees => { f.policy.apply_fees(&f.version, &f.clock); },
        Setting::Destination => { f.policy.apply_destination(&f.version, &f.clock); },
    }
}

fun cancel(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::VaultFees => {
            f
                .vault
                .cancel_protocol_lp_fees(
                    &f.version,
                    &blast_acl::witness_for_testing<CancelAdmin>()
                );
        },
        Setting::Fees => {
            f.policy.cancel_fees(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
        Setting::Destination => {
            f.policy.cancel_destination(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
    }
}

fun snapshot(f: &Fixture, setting: Setting): vector<u8> {
    match (setting) {
        Setting::VaultFees => {
            let p = f.vault.protocol_fees_for_testing();
            bcs::to_bytes(
                &vector[
                    p.raise_bps().value(),
                    p.token_bps().value(),
                    p.lp_fee_meme_bps().value(),
                    p.lp_fee_quote_bps().value()
                ]
            )
        },
        Setting::Fees => {
            let p = f.policy.fees();
            bcs::to_bytes(
                &vector[
                    p.raise_bps().value(),
                    p.token_bps().value(),
                    p.lp_fee_meme_bps().value(),
                    p.lp_fee_quote_bps().value()
                ]
            )
        },
        Setting::Destination => { bcs::to_bytes(&f.policy.destination()) },
    }
}

fun expected(setting: Setting, n: u64): vector<u8> {
    match (setting) {
        Setting::VaultFees => { bcs::to_bytes(&vector[11, 12, n, n + 1]) },
        Setting::Fees => { bcs::to_bytes(&vector[n, n + 1, n + 2, n + 3]) },
        Setting::Destination => { bcs::to_bytes(&(if (n == 100) @0x100 else if (n == 200) @0x200 else @0x300)) },
    }
}

fun assert_value(f: &Fixture, setting: Setting, n: u64) { assert_eq!(snapshot(f, setting), expected(setting, n)); }

/// Checks the primitive's last scheduled or cancelled proposal for `setting`: its owner, value
/// and full notice, and for a schedule its deadline a full notice from now.
fun assert_notice(f: &Fixture, setting: Setting, n: u64, scheduled: bool) {
    let ready_at_ms = if (scheduled) option::some(f.clock.timestamp_ms() + DELAY) else option::none();
    match (setting) {
        Setting::Fees => assert_proposal<FeesKey, ProtocolFees>(
            sui::object::id(&f.policy),
            u64_fields_bytes(vector[n, n + 1, n + 2, n + 3]),
            ready_at_ms,
        ),
        Setting::Destination => assert_proposal<DestinationKey, address>(
            sui::object::id(&f.policy),
            expected(setting, n),
            ready_at_ms,
        ),
        Setting::VaultFees => assert_proposal<ProtocolLpFeesKey, ProtocolFees>(
            sui::object::id(&f.vault),
            u64_fields_bytes(vector[11, 12, n, n + 1]),
            ready_at_ms,
        ),
    }
}

/// A schedule when `ready_at_ms` is some, else a cancellation.
fun assert_proposal<K: copy + drop + store, T: copy + drop + store>(
    owner: ID,
    value: vector<u8>,
    ready_at_ms: Option<u64>,
) {
    let (actual_owner, _, actual_value, delay_ms, actual_ready_at_ms) = if (ready_at_ms.is_some()) {
        sui::event::events_by_type<DelayedScheduled<K, T>>().pop_back().delayed_scheduled_fields()
    } else {
        sui::event::events_by_type<DelayedCancelled<K, T>>().pop_back().delayed_cancelled_fields()
    };
    assert_eq!(actual_owner, owner);
    assert_eq!(bcs::to_bytes(&actual_value), value);
    assert_eq!(delay_ms, DELAY);
    ready_at_ms.do!(|expected| assert_eq!(actual_ready_at_ms, expected));
}

fun u64_fields_bytes(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|v| bytes.append(bcs::to_bytes(&v)));
    bytes
}

// === Imports ===



use blast_presale::{
    blast_presale_package::{Self as package_version, PackageVersion}, blast_presale_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps,
    fee_policy::{Self, DestinationKey, FeePolicy, FeesKey, ProtocolFees},
    presale_vault::{Self, ProtocolLpFeesKey, Vault}
};
use blast_admin::{blast_acl, delayed::{DelayedCancelled, DelayedScheduled}};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::clock::Clock;
