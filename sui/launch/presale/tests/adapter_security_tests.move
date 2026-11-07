// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::adapter_security_tests;

// === Constants ===


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
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun adapter_stale_schedule() { exercise(Case::StaleSchedule); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun adapter_stale_apply() { exercise(Case::StaleApply); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun adapter_stale_cancel() { exercise(Case::StaleCancel); }

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun adapter_stale_remove() { exercise(Case::StaleRemove); }

#[test]
fun adapter_boundaries_and_isolation() { exercise(Case::Success); }

// === Test Helpers ===

fun exercise(case: Case) {
    let mut ctx = sui::tx_context::dummy();
    let mut version = blast_presale_package::version_for_testing(&mut ctx);
    let mut config = creation_policy::new_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(1234);
    let admin = blast_acl::witness_for_testing<VenueAdmin>();
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    config.set_quote_allowed<Quote>(
        &version,
        &blast_acl::witness_for_testing<ListingAdmin>(),
        true
    );
    if (case == Case::StaleSchedule) version.set_version_for_testing(2);
    config.schedule_venue<AdapterA>(&version, &admin, &clock);
    if (case == Case::StaleSchedule) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    config.schedule_venue<AdapterB>(&version, &admin, &clock);
    clock.set_for_testing(1234 + delay_ms() - if (case == Case::Early) 1 else 0);
    if (case == Case::Replacement) {
        config.schedule_venue<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * delay_ms() - 1);
    };
    if (case == Case::StaleCancel || case == Case::StaleRemove || case == Case::StaleApply)
        version.set_version_for_testing(2);
    if (case == Case::Cancelled || case == Case::StaleCancel || case == Case::Success)
        config.cancel_venue<AdapterA>(&version, &cancel);
    if (case == Case::Removed || case == Case::StaleRemove)
        config.remove_venue<AdapterA>(&version, &admin);
    if (case == Case::StaleCancel || case == Case::StaleRemove) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    if (case == Case::Success) {
        // Cancelling A must not cancel B. Re-admission after removal gets a new full delay.
        config.apply_venue<AdapterB>(&version, &clock);
        config.schedule_venue<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * delay_ms());
        config.apply_venue<AdapterA>(&version, &clock);
        config.remove_venue<AdapterA>(&version, &admin);
        config.schedule_venue<AdapterA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 3 * delay_ms() + 1);
        config.apply_venue<AdapterA>(&version, &clock);
        config.assert_allowed<Quote>(type_name::with_original_ids<AdapterA>());
        config.assert_allowed<Quote>(type_name::with_original_ids<AdapterB>());
    } else {
        config.apply_venue<AdapterA>(&version, &clock);
        if (case == Case::Replay) config.apply_venue<AdapterA>(&version, &clock);
    };
    destroy(config);
    destroy(version);
    destroy(clock);
}

/// Blast's 48-hour administrative delay.
fun delay_ms(): u64 {
    blast_admin::package_admin::initial_upgrade_delay_ms_for_testing()
}

// === Imports ===

use blast_admin::blast_acl;

use blast_core::blast_domain::{VenueAdmin, CancelAdmin, ListingAdmin};

use blast_presale::{blast_presale_package, creation_policy};

use std::{type_name, unit_test::destroy};
