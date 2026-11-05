// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The launchpad's unpause: it clears bits through `blast_admin::package_admin` only while every
/// launchpad notice is guarded. Pause-bit arithmetic and the upgrade notice are the generic
/// administration's and are tested there.
module blast_fun::pause_tests;

// === Test-Only Types ===

public struct ReleaseFixture {
    version: PackageVersion<BLAST_FUN>,
    package_admin: PackageAdmin<BLAST_FUN>,
    runtime_config: RuntimeConfig,
    launch_config: LaunchConfig,
}

// === Tests ===

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::package_version)]
fun stale_generation_is_rejected_before_the_notice_gate() {
    let mut f = release_fixture_with(
        runtime_config::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.version.set_generation_for_testing(2);
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun unpause_releases_once_every_notice_is_guarded() {
    let mut f = release_fixture();
    f.unpause(constants::valid_pause_bits!());
    assert_eq!(f.version.paused_for_testing(), 0);
    f.end();
}

#[test]
fun unpause_clears_only_the_requested_bits() {
    let mut f = release_fixture();
    f.unpause(constants::create_pause_bit!());
    assert_eq!(
        f.version.paused_for_testing(),
        constants::trading_pause_bit!() | constants::migration_pause_bit!(),
    );
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::launch_config)]
fun unpause_rejects_the_zero_publication_notices() {
    let mut f = release_fixture_with(
        runtime_config::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_change_to_a_zero_notice() {
    let mut f = release_fixture().with_zero_notice_fee_share_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_lp_fee_change_to_a_zero_notice() {
    let mut f = release_fixture().with_zero_notice_lp_fee_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_signer_admission() {
    let mut f = release_fixture().with_pending_signer_admission();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnguardedUpgradeNotice, location = blast_admin::package_admin)]
fun unpause_rejects_a_pending_zero_upgrade_notice() {
    let mut f = release_fixture().with_zero_upgrade_notice_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun pause_flags_name_three_independent_operations() {
    assert_eq!(constants::create_pause_bit!(), 1);
    assert_eq!(constants::trading_pause_bit!(), 2);
    assert_eq!(constants::migration_pause_bit!(), 4);
    assert_eq!(constants::valid_pause_bits!(), 7);
}

// === Test Helpers ===

/// A fully paused version with the 48-hour upgrade notice and policies whose notices were raised
/// to two days.
fun release_fixture(): ReleaseFixture {
    release_fixture_with(runtime_config::new_zero_fee_share_for_testing(&mut tx_context::dummy()))
}

fun release_fixture_with(runtime_config: RuntimeConfig): ReleaseFixture {
    let ctx = &mut tx_context::dummy();
    let mut version = otw::version_for_testing(ctx);
    package_admin::pause(&mut version, &pause_admin(), constants::valid_pause_bits!());

    ReleaseFixture {
        version,
        package_admin: otw::package_admin_for_testing(ctx),
        runtime_config,
        launch_config: launch_config::new_zero_fees_for_testing(ctx),
    }
}

fun with_zero_notice_fee_share_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, mut runtime_config, launch_config } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    runtime_config.schedule_protocol_fee_share(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(0),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config }
}

fun with_zero_notice_lp_fee_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, runtime_config, mut launch_config } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    launch_config.schedule_protocol_lp_fees(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(1_500),
        bps::new(1_500),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config }
}

fun with_pending_signer_admission(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, mut runtime_config, launch_config } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    runtime_config.schedule_creator_claim_signer(
        &version,
        &blast_acl::witness_for_testing<ClaimSignerAdmin>(),
        x"0101010101010101010101010101010101010101010101010101010101010101",
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config }
}

fun with_zero_upgrade_notice_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, mut package_admin, runtime_config, launch_config } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    package_admin.schedule_upgrade_delay(
        &blast_acl::witness_for_testing<UpgradeAdmin<BLAST_FUN>>(),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config }
}

fun unpause(self: &mut ReleaseFixture, bits: u8) {
    self.launch_config.unpause(
        &mut self.version,
        &blast_acl::witness_for_testing<UnpauseAdmin<BLAST_FUN>>(),
        &self.package_admin,
        &self.runtime_config,
        bits,
    );
}

fun end(self: ReleaseFixture) {
    destroy(self);
}

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_FUN>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::PackageVersion
};

use blast_core::{blast_domain::{ClaimSignerAdmin, FeeAdmin}, bps};

use blast_fun::{
    blast_fun::{Self as otw, BLAST_FUN},
    constants,
    launch_config::{Self, LaunchConfig},
    runtime_config::{Self, RuntimeConfig}
};

use std::unit_test::{assert_eq, destroy};
