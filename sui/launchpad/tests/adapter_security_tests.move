// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::adapter_security_tests;

// === Constants ===

const DELAY: u64 = 172_800_000;

// === Test-Only Types ===

public struct VenueA() has drop;
public struct VenueB() has drop;
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

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun venue_early() { exercise(Case::Early); }

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun venue_replacement() { exercise(Case::Replacement); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun venue_cancelled() { exercise(Case::Cancelled); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun venue_removed() { exercise(Case::Removed); }

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun venue_replay() { exercise(Case::Replay); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun venue_stale_schedule() { exercise(Case::StaleSchedule); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun venue_stale_apply() { exercise(Case::StaleApply); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun venue_stale_cancel() { exercise(Case::StaleCancel); }

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun venue_stale_remove() { exercise(Case::StaleRemove); }

#[test]
fun venue_boundaries_and_isolation() { exercise(Case::Success); }

// === Test Helpers ===

fun exercise(case: Case) {
    let mut ctx = sui::tx_context::dummy();
    let mut version = package_version::version_for_testing(&mut ctx);
    let mut config = launch_config::new_zero_fees_for_testing(&mut ctx);
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(1234);
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();
    let cancel = blast_acl::witness_for_testing<CancelAdmin>();
    config.set_quote_allowed<Quote>(
        &version,
        &blast_acl::witness_for_testing<ListingAdmin>(),
        true
    );
    if (case == Case::StaleSchedule) version.set_generation_for_testing(2);
    config.schedule_venue<VenueA>(&version, &admin, &clock);
    if (case == Case::StaleSchedule) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    config.schedule_venue<VenueB>(&version, &admin, &clock);
    clock.set_for_testing(1234 + DELAY - if (case == Case::Early) 1 else 0);
    if (case == Case::Replacement) {
        config.schedule_venue<VenueA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * DELAY - 1);
    };
    if (case == Case::StaleCancel || case == Case::StaleRemove || case == Case::StaleApply)
        version.set_generation_for_testing(2);
    if (case == Case::Cancelled || case == Case::StaleCancel || case == Case::Success)
        config.cancel_venue<VenueA>(&version, &cancel);
    if (case == Case::Removed || case == Case::StaleRemove)
        config.remove_venue<VenueA>(&version, &admin);
    if (case == Case::StaleCancel || case == Case::StaleRemove) {
        destroy(config);
        destroy(version);
        destroy(clock);
        return
    };
    if (case == Case::Success) {
        // Cancelling A must not cancel B. Re-admission after removal gets a new full notice.
        config.apply_venue<VenueB>(&version, &clock);
        config.schedule_venue<VenueA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 2 * DELAY);
        config.apply_venue<VenueA>(&version, &clock);
        config.remove_venue<VenueA>(&version, &admin);
        config.schedule_venue<VenueA>(&version, &admin, &clock);
        clock.set_for_testing(1234 + 3 * DELAY + 1);
        config.apply_venue<VenueA>(&version, &clock);
        config.snapshot_for_launch<Quote>(std::type_name::with_original_ids<VenueA>(), 9);
        config.snapshot_for_launch<Quote>(std::type_name::with_original_ids<VenueB>(), 9);
    } else {
        config.apply_venue<VenueA>(&version, &clock);
        if (case == Case::Replay) config.apply_venue<VenueA>(&version, &clock);
    };
    destroy(config);
    destroy(version);
    destroy(clock);
}

// === Imports ===

use blast_core::blast_domain::{AdapterAdmin, CancelAdmin, ListingAdmin};

use blast_fun::{
    blast_fun::{Self as package_version},
    launch_config,
};
use blast_admin::blast_acl;
use std::unit_test::destroy;
