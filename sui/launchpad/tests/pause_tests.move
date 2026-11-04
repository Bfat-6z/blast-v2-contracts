// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::pause_tests;

// === Test-Only Types ===

public struct ReleaseFixture {
    version: marker::PackageVersion,
    package_admin: PackageAdmin,
    runtime_config: RuntimeConfig,
    launch_config: LaunchConfig,
}

// === Tests ===

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidPauseBits, location = blast_fun::blast_fun)]
fun pausing_zero_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 0);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidPauseBits, location = blast_fun::blast_fun)]
fun unpausing_zero_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.clear_pause_bits(0);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidPauseBits, location = blast_fun::blast_fun)]
fun unsupported_unpause_bits_are_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.clear_pause_bits(8);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_generation_is_rejected_before_the_notice_gate() {
    let mut f = release_fixture();
    f.version.set_for_testing(2);
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun unpause_releases_once_every_notice_is_guarded() {
    let mut f = release_fixture();
    f.unpause(constants::valid_pause_bits!());
    f.version.assert_not_paused(constants::valid_pause_bits!());
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::package_admin)]
fun unpause_rejects_the_zero_publication_notices() {
    let mut f = release_fixture_with(
        runtime_config::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::package_admin)]
fun unpause_rejects_a_pending_change_to_a_zero_notice() {
    let mut f = release_fixture().with_zero_notice_fee_share_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::package_admin)]
fun unpause_rejects_a_pending_lp_fee_change_to_a_zero_notice() {
    let mut f = release_fixture().with_zero_notice_lp_fee_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::package_admin)]
fun unpause_rejects_a_pending_signer_admission() {
    let mut f = release_fixture().with_pending_signer_admission();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedNotice, location = blast_fun::package_admin)]
fun unpause_rejects_a_pending_zero_upgrade_notice() {
    let mut f = release_fixture().with_zero_upgrade_notice_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun pause_sets_only_requested_bits_and_unpause_clears_only_requested_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(
        &blast_acl::witness_for_testing<PauseAdmin>(),
        constants::create_pause_bit!() | constants::trading_pause_bit!()
    );
    version.assert_not_paused(constants::migration_pause_bit!());
    version.clear_pause_bits(constants::create_pause_bit!());
    version.assert_not_paused(constants::create_pause_bit!());
    let paused = sui::event::events_by_type<
        blast_fun::blast_events::Event<blast_fun::events::Paused>
    >();
    assert_eq!(std::bcs::to_bytes(&paused[0]), vector[3u8, 3u8]);
    let unpaused = sui::event::events_by_type<
        blast_fun::blast_events::Event<blast_fun::events::Unpaused>
    >();
    assert_eq!(std::bcs::to_bytes(&unpaused[0]), vector[1u8, 2u8]);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun clearing_create_does_not_unpause_trading() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(
        &blast_acl::witness_for_testing<PauseAdmin>(),
        constants::create_pause_bit!() | constants::trading_pause_bit!()
    );
    version.clear_pause_bits(constants::create_pause_bit!());
    version.assert_not_paused(constants::trading_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidPauseBits, location = blast_fun::blast_fun)]
fun unsupported_pause_bits_are_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 8);
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_generation_is_rejected_before_invalid_pause_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.set_for_testing(2);
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 0);
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPauseUnchanged, location = blast_fun::blast_fun)]
fun setting_already_paused_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::create_pause_bit!());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPauseUnchanged, location = blast_fun::blast_fun)]
fun clearing_unpaused_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.clear_pause_bits(constants::create_pause_bit!());
    abort
}

#[test]
fun pause_flags_name_three_independent_operations() {
    assert_eq!(constants::create_pause_bit!(), 1);
    assert_eq!(constants::trading_pause_bit!(), 2);
    assert_eq!(constants::migration_pause_bit!(), 4);
    assert_eq!(constants::valid_pause_bits!(), 7);
}

#[test]
fun every_disjoint_u8_query_is_allowed_in_every_reachable_state() {
    8u64.do!(|initial| {
        let version = version_in_state(initial as u8);
        256u64.do!(|query| {
            // An independent per-flag oracle also covers zero and unsupported query bits.
            let overlaps = vector[1u64, 2, 4].any!(
                |flag| (initial / *flag) % 2 == 1 && (query / *flag) % 2 == 1
            );
            if (!overlaps) {
                version.assert_not_paused(query as u8);
            };
        });
        destroy(version);
    });
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_1_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(1, 1);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_1_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(1, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_1_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(1, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_1_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(1, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_2_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(2, 2);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_2_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(2, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_2_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(2, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_2_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(2, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(3, 1);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(3, 2);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(3, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(3, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(3, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_3_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(3, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_4_rejects_overlapping_mask_4() {
    assert_guard_rejects_mask(4, 4);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_4_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(4, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_4_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(4, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_4_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(4, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(5, 1);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(5, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_4() {
    assert_guard_rejects_mask(5, 4);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(5, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(5, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_5_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(5, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(6, 2);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(6, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_4() {
    assert_guard_rejects_mask(6, 4);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(6, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(6, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_6_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(6, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(7, 1);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(7, 2);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(7, 3);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_4() {
    assert_guard_rejects_mask(7, 4);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_5() {
    assert_guard_rejects_mask(7, 5);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_6() {
    assert_guard_rejects_mask(7, 6);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun paused_state_7_rejects_overlapping_mask_7() {
    assert_guard_rejects_mask(7, 7);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_1() {
    assert_guard_rejects_mask(1, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_2() {
    assert_guard_rejects_mask(2, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_3() {
    assert_guard_rejects_mask(3, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_4() {
    assert_guard_rejects_mask(4, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_5() {
    assert_guard_rejects_mask(5, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_6() {
    assert_guard_rejects_mask(6, 255);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun unsupported_query_bits_do_not_hide_paused_state_7() {
    assert_guard_rejects_mask(7, 255);
}

// === Test Helpers ===

/// Publication-paused generation with the 48-hour upgrade notice and policies whose notices
/// were raised to two days.
fun release_fixture(): ReleaseFixture {
    release_fixture_with(runtime_config::new_zero_fee_share_for_testing(&mut tx_context::dummy()))
}

fun release_fixture_with(runtime_config: RuntimeConfig): ReleaseFixture {
    let ctx = &mut tx_context::dummy();
    let mut version = marker::new_for_testing(ctx);
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::valid_pause_bits!());

    ReleaseFixture {
        version,
        package_admin: package_admin::new_for_testing(ctx),
        runtime_config,
        launch_config: launch_config::new_zero_fees_for_testing(ctx),
    }
}

fun with_zero_notice_fee_share_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, mut runtime_config, launch_config } =
        self;
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
    let ReleaseFixture { version, package_admin, mut runtime_config, launch_config } =
        self;
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
    let ReleaseFixture { version, mut package_admin, runtime_config, launch_config } =
        self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    package_admin.schedule_upgrade_delay(
        &version,
        &blast_acl::witness_for_testing<UpgradeAdmin>(),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config }
}

fun unpause(self: &mut ReleaseFixture, bits: u8) {
    self.package_admin.unpause(
        &mut self.version,
        &blast_acl::witness_for_testing<UnpauseAdmin>(),
        &self.runtime_config,
        &self.launch_config,
        bits,
    );
}

fun end(self: ReleaseFixture) {
    destroy(self);
}

fun version_in_state(initial: u8): marker::PackageVersion {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    if (initial != 0) {
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), initial);
    };
    version
}

fun assert_guard_rejects_mask(initial: u8, query: u8) {
    let version = version_in_state(initial);
    version.assert_not_paused(query);
    destroy(version);
}

// === Imports ===

use blast_admin::blast_acl;
use blast_core::bps;

use blast_fun::{
    blast_fun as marker,
    blast_fun_domain::{ClaimSignerAdmin, FeeAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    constants,
    launch_config::{Self, LaunchConfig},
    package_admin::{Self, PackageAdmin},
    runtime_config::{Self, RuntimeConfig},
};
use std::unit_test::{assert_eq, destroy};
