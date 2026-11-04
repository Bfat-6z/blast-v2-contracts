// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_vault::blast_vault_package_tests;

// === Constants ===

const ADMISSION_NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// A venue that applies for admission during a test.
public struct NewVenue() has drop;

// === Tests ===

// Launch

#[test]
/// Publication leaves the package fully paused with a zero admission notice: Blast lists its
/// venues at once, raises the notice, and only then unpauses.
fun venues_are_listed_at_launch_while_the_package_is_paused() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::valid_pause_bits!());

    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    registry.apply_venue<NewVenue>(f.version(), f.clock());
    registry.schedule_venue_delay(&adapter_admin(), f.version(), ADMISSION_NOTICE_MS, f.clock());
    registry.apply_venue_delay(f.version(), f.clock());
    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        constants::valid_pause_bits!(),
    );

    assert_eq!(f.version().paused_for_testing(), 0);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let vault = vault::new<VAULT_FIXTURE, QUOTE, _>(
        &registry,
        &NewVenue(),
        f.version(),
        terms,
        vault_fixture::pool_id(),
        scenario.ctx(),
    );
    destroy(vault);
    destroy(package_admin);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedNotice,
    location = blast_vault::blast_vault_package,
)]
fun unpause_waits_for_a_nonzero_admission_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedNotice,
    location = blast_vault::blast_vault_package,
)]
fun unpause_waits_while_a_zero_admission_notice_is_pending() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    registry.schedule_venue_delay(&adapter_admin(), f.version(), 0, f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnguardedNotice,
    location = blast_vault::blast_vault_package,
)]
/// An admission still pending when the notice is raised keeps the set unguarded until it is
/// applied or cancelled.
fun unpause_waits_while_an_admission_is_pending() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        constants::admin_pause_bit!(),
    );

    abort
}

#[test]
fun venues_are_admitted_while_paused_after_launch() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS);
    registry.apply_venue<NewVenue>(f.version(), f.clock());

    destroy(registry);
    f.end();
    scenario.end();
}

// Venue admission after launch

#[test]
fun an_admitted_venue_creates_vaults_after_its_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS);

    registry.apply_venue<NewVenue>(f.version(), f.clock());

    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    let vault = vault::new<VAULT_FIXTURE, QUOTE, _>(
        &registry,
        &NewVenue(),
        f.version(),
        terms,
        vault_fixture::pool_id(),
        scenario.ctx(),
    );
    destroy(vault);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun a_venue_cannot_be_admitted_before_its_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS - 1);

    registry.apply_venue<NewVenue>(f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_admission_cannot_apply() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    registry.cancel_venue<NewVenue>(&cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS);

    registry.apply_venue<NewVenue>(f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedVenue,
    location = blast_vault::blast_vault_package,
)]
fun a_removed_venue_cannot_create_vaults() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::registry_for_testing<NewVenue>(scenario.ctx());
    registry.remove_venue<NewVenue>(&adapter_admin(), f.version());

    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    destroy(
        vault::new<VAULT_FIXTURE, QUOTE, _>(
            &registry,
            &NewVenue(),
            f.version(),
            terms,
            vault_fixture::pool_id(),
            scenario.ctx(),
        ),
    );

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidVenue,
    location = blast_vault::blast_vault_package,
)]
fun a_primitive_type_cannot_be_a_venue() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_venue<u64>(&adapter_admin(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidVenue,
    location = blast_vault::blast_vault_package,
)]
fun a_move_standard_library_type_cannot_be_a_venue() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_venue<std::string::String>(&adapter_admin(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidVenue,
    location = blast_vault::blast_vault_package,
)]
fun a_sui_framework_type_cannot_be_a_venue() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::empty_registry_for_testing(scenario.ctx());

    registry.schedule_venue<ID>(&adapter_admin(), f.version(), f.clock());

    abort
}

#[test]
fun the_admin_pause_never_stops_cancellation_or_removal() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = blast_vault_package::registry_for_testing<TestVenue>(scenario.ctx());
    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.cancel_venue<NewVenue>(&cancel_admin(), f.version());
    registry.remove_venue<TestVenue>(&adapter_admin(), f.version());

    destroy(registry);
    f.end();
    scenario.end();
}

// Unpause and notice changes

#[test]
fun unpause_clears_the_bits_while_every_notice_is_guarded() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let registry = guarded_registry(&f, scenario.ctx());
    let package_admin = new_package_admin(scenario.ctx());
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    registry.unpause(
        &unpause_admin(),
        &package_admin,
        f.version_mut(),
        constants::admin_pause_bit!(),
    );

    assert_eq!(f.version().paused_for_testing(), 0);
    destroy(package_admin);
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
fun an_admission_notice_change_applies_after_the_current_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_venue_delay(&adapter_admin(), f.version(), 1, f.clock());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS);
    registry.apply_venue_delay(f.version(), f.clock());

    registry.schedule_venue<NewVenue>(&adapter_admin(), f.version(), f.clock());
    f.clock_mut().increment_for_testing(1);
    registry.apply_venue<NewVenue>(f.version(), f.clock());

    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_admission_notice_change_cannot_apply() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let mut registry = guarded_registry(&f, scenario.ctx());
    registry.schedule_venue_delay(&adapter_admin(), f.version(), 1, f.clock());
    registry.cancel_venue_delay(&cancel_admin(), f.version());
    f.clock_mut().increment_for_testing(ADMISSION_NOTICE_MS);

    registry.apply_venue_delay(f.version(), f.clock());

    abort
}

// === Test Helpers ===

/// A registry after launch: nothing admitted, with the 48-hour admission notice applied.
fun guarded_registry(f: &VaultFixture, ctx: &mut TxContext): VaultRegistry {
    let mut registry = blast_vault_package::empty_registry_for_testing(ctx);
    registry.schedule_venue_delay(&adapter_admin(), f.version(), ADMISSION_NOTICE_MS, f.clock());
    registry.apply_venue_delay(f.version(), f.clock());

    registry
}

/// Package administration for the vault package with its production upgrade notice.
fun new_package_admin(ctx: &mut TxContext): PackageAdmin<BLAST_VAULT_PACKAGE> {
    package_admin::new_for_testing(
        package::test_claim(test_utils::create_one_time_witness<BLAST_VAULT_PACKAGE>(), ctx),
        package::test_publish(@blast_vault.to_id(), ctx),
        ctx,
    )
}

fun adapter_admin(): AdminWitness<AdapterAdmin> { blast_acl::witness_for_testing() }

fun cancel_admin(): AdminWitness<CancelAdmin> { blast_acl::witness_for_testing() }

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

fun unpause_admin(): AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin}
};

use blast_core::blast_domain::{AdapterAdmin, CancelAdmin};

use blast_vault::{
    blast_vault_package::{Self, BLAST_VAULT_PACKAGE, VaultRegistry},
    constants,
    vault,
    vault_fixture::{Self, QUOTE, TestVenue, VAULT_FIXTURE, VaultFixture, owner_split}
};

use std::unit_test::{assert_eq, destroy};

use sui::{package, test_utils};
