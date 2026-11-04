// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::adapter_security_tests;

// === Constants ===

const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public struct AdapterA() has drop;
public struct AdapterB() has drop;
public struct Quote() has drop;
public enum Case has copy, drop {
    Early,
    Replacement,
    Cancelled,
    Removed,
    Replay,
    StaleSchedule,
    StaleApply,
    StaleCancel,
    StaleRemove,
    Success,
}

// === Tests ===

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed_set,
)]
fun adapter_early() { exercise(Case::Early); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENotReady,
    location = blast_admin::delayed_set,
)]
fun adapter_replacement() { exercise(Case::Replacement); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed_set,
)]
fun adapter_cancelled() { exercise(Case::Cancelled); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed_set,
)]
fun adapter_removed() { exercise(Case::Removed); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::ENoPending,
    location = blast_admin::delayed_set,
)]
fun adapter_replay() { exercise(Case::Replay); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun adapter_stale_schedule() { exercise(Case::StaleSchedule); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun adapter_stale_apply() { exercise(Case::StaleApply); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun adapter_stale_cancel() { exercise(Case::StaleCancel); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun adapter_stale_remove() { exercise(Case::StaleRemove); }

#[test]
fun adapter_boundaries_and_isolation() { exercise(Case::Success); }

// === Test Helpers ===

fun exercise(case: Case) {
    let mut ctx = sui::tx_context::dummy();
    let mut version = package_version::new_for_testing(&mut ctx);
    let mut config = creation_policy::new_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(1234);
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    config.set_quote_allowed<Quote>(
        &version,
        &blast_acl::witness_for_testing<ListingAdmin>(),
        true
    );
    if (case == Case::StaleSchedule) version.set_for_testing(2);
    config.schedule_migration_witness<AdapterA>(&version, &admin, &clock);
    if (case == Case::StaleSchedule) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    config.schedule_migration_witness<AdapterB>(&version, &admin, &clock);
    clock.set_for_testing(1234 + DELAY - if (case == Case::Early) 1 else 0);
    if (case == Case::Replacement) {
        config.schedule_migration_witness<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * DELAY - 1);
    };
    if (case == Case::StaleCancel || case == Case::StaleRemove || case == Case::StaleApply)
        version.set_for_testing(2);
    if (case == Case::Cancelled || case == Case::StaleCancel || case == Case::Success)
        config.cancel_migration_witness<AdapterA>(&version, &cancel);
    if (case == Case::Removed || case == Case::StaleRemove)
        config.remove_migration_witness<AdapterA>(&version, &admin);
    if (case == Case::StaleCancel || case == Case::StaleRemove) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    if (case == Case::Success) {
        // Cancelling A must not cancel B. Re-admission after removal gets a new full notice.
        config.apply_migration_witness<AdapterB>(&version, &clock);
        config.schedule_migration_witness<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * DELAY);
        config.apply_migration_witness<AdapterA>(&version, &clock);
        config.remove_migration_witness<AdapterA>(&version, &admin);
        config.schedule_migration_witness<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 3 * DELAY + 1);
        config.apply_migration_witness<AdapterA>(&version, &clock);
        config.assert_allowed<Quote, AdapterA>();
        config.assert_allowed<Quote, AdapterB>();
    } else {
        config.apply_migration_witness<AdapterA>(&version, &clock);
        if (case == Case::Replay) config.apply_migration_witness<AdapterA>(&version, &clock);
    };
    destroy(config);
    destroy(version);
    destroy(clock);
}

// === Imports ===

use blast_presale::{
    blast_presale_package::{Self as package_version}, creation_policy,
    blast_presale_domain::{AdapterAdmin, CancelAdmin, ListingAdmin}
};
use blast_admin::blast_acl;
use std::unit_test::destroy;
