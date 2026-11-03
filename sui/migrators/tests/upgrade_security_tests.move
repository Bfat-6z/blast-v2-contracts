// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::upgrade_security_tests;

// === Constants ===

const START: u64 = 1_234;
const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public enum Case has copy, drop {
    Missing,
    Early,
    Replacement,
    Cancelled,
    Replay,
    WrongKind,
    StaleSchedule,
    StaleApply,
    StaleCancel,
    Exact,
    Late,
    Reschedule,
}
public struct Fixture {
    version: PackageVersion,
    admin: PackageAdmin,
    clock: Clock
}

// === Tests ===

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun upgrade_missing() { exercise(false, Case::Missing); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun upgrade_early() { exercise(false, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun upgrade_replacement() { exercise(false, Case::Replacement); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun upgrade_cancelled() { exercise(false, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun upgrade_replay() { exercise(false, Case::Replay); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::EWrongUpgradeAction, location = blast_fun_migrators::package_admin)]
fun upgrade_wrong_kind() { exercise(false, Case::WrongKind); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun upgrade_stale_schedule() { exercise(false, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun upgrade_stale_apply() { exercise(false, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun upgrade_stale_cancel() { exercise(false, Case::StaleCancel); }

#[test]
fun upgrade_exact_ready() { exercise(false, Case::Exact); }

#[test]
fun upgrade_after_ready() { exercise(false, Case::Late); }

#[test]
fun upgrade_cancel_then_reschedule() { exercise(false, Case::Reschedule); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun immutable_missing() { exercise(true, Case::Missing); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun immutable_early() { exercise(true, Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun immutable_replacement() { exercise(true, Case::Replacement); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun immutable_cancelled() { exercise(true, Case::Cancelled); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::ENoPendingAction, location = blast_fun_migrators::package_admin)]
fun immutable_replay() { exercise(true, Case::Replay); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::EWrongUpgradeAction, location = blast_fun_migrators::package_admin)]
fun immutable_wrong_kind() { exercise(true, Case::WrongKind); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun immutable_stale_schedule() { exercise(true, Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun immutable_stale_apply() { exercise(true, Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun immutable_stale_cancel() { exercise(true, Case::StaleCancel); }

#[test]
fun immutable_exact_ready() { exercise(true, Case::Exact); }

#[test]
fun immutable_after_ready() { exercise(true, Case::Late); }

#[test]
fun immutable_cancel_then_reschedule() { exercise(true, Case::Reschedule); }

#[test, expected_failure(abort_code = blast_fun_migrators::package_admin::EWrongUpgradeAction, location = blast_fun_migrators::package_admin)]
fun upgrade_wrong_digest() {
    let mut f = start();
    schedule(&mut f, false);
    f.clock.set_for_testing(START + DELAY);
    let r = &mut f;
    destroy(r
        .admin
        .authorize_upgrade(
            &r.version,
            &blast_acl::witness_for_testing<UpgradeAdmin>(),
            vector::tabulate!(32, |_| 1u8),
            &r.clock
        ));
    destroy(f);
}

#[test, expected_failure(abort_code = blast_admin::errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun immutable_destroys_upgrade_authority() {
    let mut f = start();
    schedule(&mut f, true);
    f.clock.set_for_testing(START + DELAY);
    apply(&mut f, true);
    schedule(&mut f, false);
    f.clock.set_for_testing(START + 2 * DELAY);
    apply(&mut f, false);
    destroy(f);
}

#[test]
#[expected_failure(abort_code = blast_fun_migrators::package_admin::EInvalidDigest, location = blast_fun_migrators::package_admin)]
fun upgrade_digest_rejects_0_bytes() {
    let mut f = start();
    let r = &mut f;
    r
        .admin
        .schedule_upgrade(
            &r.version,
            &blast_acl::witness_for_testing<UpgradeAdmin>(),
            vector::tabulate!(0, |_| 0u8),
            &r.clock
        );
    destroy(f);
}

#[test]
#[expected_failure(abort_code = blast_fun_migrators::package_admin::EInvalidDigest, location = blast_fun_migrators::package_admin)]
fun upgrade_digest_rejects_31_bytes() {
    let mut f = start();
    let r = &mut f;
    r
        .admin
        .schedule_upgrade(
            &r.version,
            &blast_acl::witness_for_testing<UpgradeAdmin>(),
            vector::tabulate!(31, |_| 0u8),
            &r.clock
        );
    destroy(f);
}

#[test]
#[expected_failure(abort_code = blast_fun_migrators::package_admin::EInvalidDigest, location = blast_fun_migrators::package_admin)]
fun upgrade_digest_rejects_33_bytes() {
    let mut f = start();
    let r = &mut f;
    r
        .admin
        .schedule_upgrade(
            &r.version,
            &blast_acl::witness_for_testing<UpgradeAdmin>(),
            vector::tabulate!(33, |_| 0u8),
            &r.clock
        );
    destroy(f);
}

// === Test Helpers ===

fun exercise(immutable: bool, case: Case) {
    let mut f = start();
    if (case == Case::StaleSchedule) f.version.set_for_testing(2);
    if (case != Case::Missing) schedule(&mut f, immutable);
    if (case == Case::StaleSchedule) {
        destroy(f);
        return
    };
    f.clock.set_for_testing(if (case == Case::Early) START + DELAY - 1 else START + DELAY);
    if (case == Case::StaleCancel) {
        f.version.set_for_testing(2);
        cancel(&mut f);
        destroy(f);
        return
    };
    if (case == Case::Replacement) {
        schedule(&mut f, immutable);
        f.clock.set_for_testing(START + 2 * DELAY - 1);
    };
    if (case == Case::Cancelled || case == Case::Reschedule) {
        cancel(&mut f);
        if (case == Case::Reschedule) {
            schedule(&mut f, immutable);
            f.clock.set_for_testing(START + 2 * DELAY);
        };
    };
    if (case == Case::StaleApply) f.version.set_for_testing(2);
    if (case == Case::Late) f.clock.set_for_testing(START + DELAY + 1);
    apply(&mut f, if (case == Case::WrongKind) !immutable else immutable);
    if (case == Case::Replay) apply(&mut f, immutable);
    destroy(f);
}

fun start(): Fixture {
    let mut ctx = sui::tx_context::dummy();
    let version = package_version::new_for_testing(&mut ctx);
    let admin = package_admin::new_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(START);
    Fixture { version, admin, clock }
}

fun schedule(f: &mut Fixture, immutable: bool) {
    let admin = blast_acl::witness_for_testing<UpgradeAdmin>();
    if (immutable) f.admin.schedule_make_immutable(&f.version, &admin, &f.clock)
    else f.admin.schedule_upgrade(&f.version, &admin, digest(), &f.clock);
}

fun apply(f: &mut Fixture, immutable: bool) {
    let admin = blast_acl::witness_for_testing<UpgradeAdmin>();
    if (immutable) f.admin.make_immutable(&f.version, &admin, &f.clock)
    else {
        let ticket = f.admin.authorize_upgrade(&f.version, &admin, digest(), &f.clock);
        assert_eq!(*ticket.ticket_digest(), digest());
        destroy(ticket);
    };
}

fun cancel(f: &mut Fixture) {
    f.admin.cancel_upgrade_action(&f.version, &blast_acl::witness_for_testing<CancelAdmin>());
}

fun digest(): vector<u8> { vector::tabulate!(32, |_| 0u8) }

// === Imports ===

use blast_fun_migrators::{blast_fun_migrators::{Self as package_version, PackageVersion}, package_admin::{Self, PackageAdmin}};
use blast_fun::blast_fun_domain::{CancelAdmin, UpgradeAdmin};
use blast_admin::blast_acl;
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
