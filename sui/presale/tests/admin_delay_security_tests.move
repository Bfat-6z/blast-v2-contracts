// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::admin_delay_security_tests;

// === Constants ===

const START: u64 = 1_234;

// === Test-Only Types ===

public enum Setting has copy, drop, store {
    Fees,
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
    version: PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: Clock,
    policy: FeePolicy,
}


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

// === Test Helpers ===

/// Tests use a nonzero start so absolute timestamps cannot accidentally satisfy the delay.
fun exercise(setting: Setting, case: Case) {
    let mut f = start(setting);
    let initial = snapshot(&f, setting);
    if (case == Case::StaleSchedule) f.version.set_generation_for_testing(2);
    schedule(&mut f, setting, 100);
    assert_notice(&f, setting, 100, true);
    assert_eq!(snapshot(&f, setting), initial);
    f.clock.set_for_testing(START + delay_ms() - if (case == Case::Early) 1 else 0);
    assert_eq!(snapshot(&f, setting), initial);
    match (case) {
        Case::Early => {
            apply(&mut f, setting);
            destroy(f);
        },
        Case::Replacement => {
            schedule(&mut f, setting, 200);
            assert_notice(&f, setting, 200, true);
            f.clock.set_for_testing(START + 2 * delay_ms() - 1);
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
            f.version.set_generation_for_testing(2);
            apply(&mut f, setting);
            destroy(f);
        },
        Case::StaleCancel => {
            f.version.set_generation_for_testing(2);
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
            f.clock.set_for_testing(START + 2 * delay_ms());
            apply(&mut f, setting);
            assert_value(&f, setting, 100);
            // Replacement of a ready action keeps the applied value until explicit application.
            prepare_again(&mut f, setting);
            schedule(&mut f, setting, 200);
            assert_notice(&f, setting, 200, true);
            f.clock.set_for_testing(START + 4 * delay_ms());
            schedule(&mut f, setting, 300);
            assert_notice(&f, setting, 300, true);
            let before = snapshot(&f, setting);
            f.clock.set_for_testing(START + 5 * delay_ms() + 1);
            assert_eq!(snapshot(&f, setting), before);
            apply(&mut f, setting);
            assert_value(&f, setting, 300);
            destroy(f);
        },
    };
}

fun start(setting: Setting): Fixture {
    let mut ctx = sui::tx_context::dummy();
    let version = blast_presale_package::version_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(START);
    let _ = setting;
    Fixture { version, clock, policy: fee_policy::new_zero_fees_for_testing(&mut ctx) }
}

fun prepare_again(f: &mut Fixture, setting: Setting) {
    let _ = f;
    let _ = setting;
}

fun schedule(f: &mut Fixture, setting: Setting, n: u64) {
    match (setting) {
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
                    delay_ms(),
                    &f.clock
                );
        },
    }
}

fun apply(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::Fees => { f.policy.apply_fees(&f.version, &f.clock); },
    }
}

fun cancel(f: &mut Fixture, setting: Setting) {
    match (setting) {
        Setting::Fees => {
            f.policy.cancel_fees(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
        },
    }
}

fun snapshot(f: &Fixture, setting: Setting): vector<u8> {
    match (setting) {
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
    }
}

fun expected(setting: Setting, n: u64): vector<u8> {
    match (setting) {
        Setting::Fees => { bcs::to_bytes(&vector[n, n + 1, n + 2, n + 3]) },
    }
}

fun assert_value(f: &Fixture, setting: Setting, n: u64) { assert_eq!(snapshot(f, setting), expected(setting, n)); }

/// Checks the primitive's last scheduled or cancelled proposal for `setting`: its owner, value
/// and full notice, and for a schedule its deadline a full notice from now.
fun assert_notice(f: &Fixture, setting: Setting, n: u64, scheduled: bool) {
    let ready_at_ms = if (scheduled) option::some(f.clock.timestamp_ms() + delay_ms()) else option::none();
    match (setting) {
        Setting::Fees => assert_proposal<FeesKey, ProtocolFees>(
            sui::object::id(&f.policy),
            u64_fields_bytes(vector[n, n + 1, n + 2, n + 3]),
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
    assert_eq!(delay_ms, delay_ms());
    ready_at_ms.do!(|expected| assert_eq!(actual_ready_at_ms, expected));
}

fun u64_fields_bytes(values: vector<u64>): vector<u8> {
    let mut bytes = vector[];
    values.do!(|v| bytes.append(bcs::to_bytes(&v)));
    bytes
}

/// Blast's 48-hour administrative notice.
fun delay_ms(): u64 {
    blast_admin::package_admin::initial_upgrade_delay_ms_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl,
    delayed::{DelayedCancelled, DelayedScheduled},
    package_version::PackageVersion
};

use blast_core::{blast_domain::{CancelAdmin, FeeAdmin}, bps};

use blast_presale::{
    blast_presale_package::{Self, BLAST_PRESALE_PACKAGE},
    fee_policy::{Self, FeePolicy, FeesKey, ProtocolFees}
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::clock::Clock;
