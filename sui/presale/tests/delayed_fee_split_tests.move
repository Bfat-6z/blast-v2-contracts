// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Creator policy state transitions; native venue tests enforce position settlement.
module blast_presale::delayed_fee_split_tests;

// === Constants ===

const START: u64 = 1_234;
const NOTICE: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct Meme has drop {}
public struct Quote has drop {}
public struct Fixture {
    version: PackageVersion,
    clock: Clock,
    cap: PresaleCap,
    wrong_cap: PresaleCap,
    vault: Vault<Meme, Quote>,
}

public enum Case has copy, drop {
    Early,
    Missing,
    Replay,
    Cancelled,
    Replacement,
    Unchanged,
    WrongSchedule,
    WrongCancel,
    StaleSchedule,
    StaleCancel,
    OverflowSchedule,
    OverflowApply,
    EmptyCancel,
}

public struct ExpectedScheduled has copy, drop {
    vault_id: ID,
    proposed: FeeSplit,
    ready_at_ms: u64,
    delay_ms: u64,
}
public struct ExpectedCancelled has copy, drop { vault_id: ID, proposed: FeeSplit }
public struct ExpectedChanged has copy, drop {
    vault_id: ID,
    old_fee_split: FeeSplit,
    new_fee_split: FeeSplit,
    delay_ms: u64,
}

// === Tests ===

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun before_deadline_rejects_even_zero_next_notice() {
    exercise(Case::Early);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun apply_without_proposal() {
    exercise(Case::Missing);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun applied_proposal_cannot_replay() {
    exercise(Case::Replay);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun cancelled_proposal_cannot_apply() {
    exercise(Case::Cancelled);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed,
)]
fun replacement_restarts_the_applied_notice() {
    exercise(Case::Replacement);
}

#[test]
#[expected_failure(
    abort_code = presale_vault::EFeeSplitUnchanged,
    location = blast_presale::presale_vault,
)]
fun unchanged_value_and_notice_rejected() {
    exercise(Case::Unchanged);
}

#[test]
#[expected_failure(
    abort_code = presale_vault::EWrongPresaleCap,
    location = blast_presale::presale_vault,
)]
fun wrong_cap_precedes_unchanged_validation() {
    exercise(Case::WrongSchedule);
}

#[test]
#[expected_failure(
    abort_code = presale_vault::EWrongPresaleCap,
    location = blast_presale::presale_vault,
)]
fun wrong_cap_precedes_no_pending_cancel() {
    exercise(Case::WrongCancel);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_cap_and_value_validation() {
    exercise(Case::StaleSchedule);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_cap_and_pending_validation() {
    exercise(Case::StaleCancel);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidDelay,
    location = blast_admin::delayed,
)]
fun maximum_next_notice_cannot_overflow() {
    exercise(Case::OverflowSchedule);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidDelay,
    location = blast_admin::delayed,
)]
fun late_application_rechecks_notice_representability() {
    exercise(Case::OverflowApply);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed,
)]
fun cancel_without_pending() {
    exercise(Case::EmptyCancel);
}

#[test]
fun old_split_remains_active_at_and_after_deadline_until_explicit_apply() {
    let mut f = start();
    f.schedule(next_split(), 0);
    let (value, notice, pending) = f.vault.fee_split_policy_for_testing();
    assert_eq!(value, initial_split());
    assert_eq!(notice, NOTICE);
    assert_eq!(pending.destroy_some().ready_at_ms(), START + NOTICE);
    f.clock.set_for_testing(START + NOTICE + 7);
    assert_eq!(f.applied(), initial_split());
    f.apply();
    f.assert_applied(next_split(), 0);
    assert_eq!(
        bcs::to_bytes(&event::events_by_type<presale_vault::FeeSplitScheduled>()[0]),
        bcs::to_bytes(
            &ExpectedScheduled {
                vault_id: object::id(&f.vault),
                proposed: next_split(),
                ready_at_ms: START + NOTICE,
                delay_ms: 0,
            },
        ),
    );
    assert_eq!(
        bcs::to_bytes(&event::events_by_type<presale_vault::FeeSplitChanged<Meme, Quote>>()[0]),
        bcs::to_bytes(
            &ExpectedChanged {
                vault_id: object::id(&f.vault),
                old_fee_split: initial_split(),
                new_fee_split: next_split(),
                delay_ms: 0,
            },
        ),
    );
    // Applied zero notice permits a later explicitly applied proposal in the same timestamp.
    f.schedule(initial_split(), 0);
    f.apply();
    assert_eq!(f.applied(), initial_split());
    destroy(f);
}

#[test]
fun cancel_ready_proposal_preserves_notice_and_reschedule_waits_again() {
    let mut f = start();
    f.schedule(next_split(), 0);
    f.clock.set_for_testing(START + NOTICE);
    f.cancel();
    f.assert_applied(initial_split(), NOTICE);
    assert_eq!(
        bcs::to_bytes(&event::events_by_type<presale_vault::FeeSplitCancelled>()[0]),
        bcs::to_bytes(
            &ExpectedCancelled { vault_id: object::id(&f.vault), proposed: next_split() },
        ),
    );
    f.schedule(next_split(), 25);
    f.clock.set_for_testing(START + 2 * NOTICE);
    f.apply();
    f.assert_applied(next_split(), 25);
    destroy(f);
}

#[test]
fun delay_only_change_is_announced_and_does_not_change_recipients() {
    let mut f = start();
    f.schedule(initial_split(), 25);
    f.clock.set_for_testing(START + NOTICE);
    f.apply();
    f.assert_applied(initial_split(), 25);
    f.schedule(next_split(), 25);
    f.clock.set_for_testing(START + NOTICE + 25);
    f.apply();
    assert_eq!(f.applied(), next_split());
    destroy(f);
}

#[test]
#[expected_failure(
    abort_code = presale_vault::EWrongPresaleCap,
    location = blast_presale::presale_vault,
)]
fun standalone_vault_has_no_creator_cap_authority() {
    let f = start();
    let mut ctx = sui::tx_context::dummy();
    let mut standalone = presale_vault::new_for_testing<Meme, Quote>(
        object::id_from_address(@0x0),
        object::id_from_address(@0x0),
        initial_split(),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        &mut ctx,
    );
    standalone.schedule_fee_split(&f.version, &f.cap, next_split(), 0, &f.clock);
    destroy(standalone);
    destroy(f);
}

// === Test Helpers ===

fun initial_split(): FeeSplit {
    presale::fee_split(vector[], bps::new(10_000))
}

fun next_split(): FeeSplit {
    presale::fee_split(vector[presale::recipient_share(@0xB, bps::new(10_000))], bps::new(0))
}

fun start(): Fixture {
    let mut ctx = sui::tx_context::dummy();
    let version = package_version::new_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(START);
    let sale = object::id_from_address(@0xCAFE);
    let cap = presale::cap_for_testing(sale, &mut ctx);
    let wrong_cap = presale::cap_for_testing(sale, &mut ctx);
    let vault = presale_vault::new_for_testing<Meme, Quote>(
        sale,
        object::id(&cap),
        initial_split(),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        &mut ctx,
    );
    Fixture { version, clock, cap, wrong_cap, vault }
}

fun schedule(f: &mut Fixture, split: FeeSplit, next_delay: u64) {
    f.vault.schedule_fee_split(&f.version, &f.cap, split, next_delay, &f.clock);
}

fun assert_applied(f: &Fixture, expected: FeeSplit, notice: u64) {
    let (value, delay, pending) = f.vault.fee_split_policy_for_testing();
    assert_eq!(value, expected);
    assert_eq!(delay, notice);
    assert!(pending.is_none());
}

fun applied(f: &Fixture): FeeSplit {
    let (value, _, _) = f.vault.fee_split_policy_for_testing();
    value
}

fun cancel(f: &mut Fixture) {
    f.vault.cancel_fee_split(&f.version, &f.cap);
}

fun wrong_cancel(f: &mut Fixture) {
    f.vault.cancel_fee_split(&f.version, &f.wrong_cap);
}

fun wrong_schedule(f: &mut Fixture) {
    f.vault.schedule_fee_split(&f.version, &f.wrong_cap, initial_split(), NOTICE, &f.clock);
}

fun apply(f: &mut Fixture) {
    f.vault.assert_fee_split_ready(&f.clock);
    f.vault.apply_fee_split(&f.clock);
}

fun exercise(case: Case) {
    let mut f = start();
    match (case) {
        Case::Missing => f.apply(),
        Case::EmptyCancel => f.cancel(),
        Case::WrongSchedule => f.wrong_schedule(),
        Case::WrongCancel => f.wrong_cancel(),
        Case::StaleSchedule => {
            f.version.set_for_testing(2);
            f.wrong_schedule();
        },
        Case::StaleCancel => {
            f.version.set_for_testing(2);
            f.wrong_cancel();
        },
        Case::Unchanged => f.schedule(initial_split(), NOTICE),
        Case::OverflowSchedule => f.schedule(next_split(), 18_446_744_073_709_551_615),
        Case::OverflowApply => {
            f.schedule(next_split(), 18_446_744_073_709_551_615 - START - NOTICE);
            f.clock.set_for_testing(START + NOTICE + 1);
            f.apply();
        },
        _ => {
            f.schedule(next_split(), 0);
            f.clock.set_for_testing(START + NOTICE - if (case == Case::Early) 1 else 0);
            match (case) {
                Case::Cancelled => f.cancel(),
                Case::Replacement => {
                    f.schedule(next_split(), 0);
                    f.clock.set_for_testing(START + 2 * NOTICE - 1);
                },
                Case::Replay => f.apply(),
                _ => (),
            };
            f.apply();
        },
    };
    destroy(f);
}

// === Imports ===

use blast_presale::{
    blast_presale::{Self as presale, FeeSplit, PresaleCap},
    blast_presale_package::{Self as package_version, PackageVersion},
    bps,
    fee_policy,
    presale_vault::{Self, Vault}
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::Clock, event};
