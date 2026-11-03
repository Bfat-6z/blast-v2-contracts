// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::pause_tests;

// === Tests ===

#[test]
#[expected_failure(abort_code = marker::EInvalidPauseBits, location = blast_presale::blast_presale_package)]
fun pausing_zero_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 0);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = marker::EInvalidPauseBits, location = blast_presale::blast_presale_package)]
fun unpausing_zero_bits_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 0);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = marker::EInvalidPauseBits, location = blast_presale::blast_presale_package)]
fun unsupported_unpause_bits_are_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 4);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun stale_generation_is_rejected_before_invalid_unpause_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.set_for_testing(2);
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 0);
    destroy(version);
}

#[test]
fun pause_sets_only_requested_bits_and_unpause_clears_only_requested_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 1 | 2);
    version.assert_not_paused(8);
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 1);
    version.assert_not_paused(1);
    let paused = sui::event::events_by_type<marker::Paused>();
    assert_eq!(std::bcs::to_bytes(&paused[0]), vector[3u8, 3u8]);
    let unpaused = sui::event::events_by_type<marker::Unpaused>();
    assert_eq!(std::bcs::to_bytes(&unpaused[0]), vector[1u8, 2u8]);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun clearing_create_does_not_unpause_buy() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 3);
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 1);
    version.assert_not_paused(2);
    abort
}

#[test]
#[expected_failure(abort_code = marker::EInvalidPauseBits, location = blast_presale::blast_presale_package)]
fun unsupported_pause_bits_are_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 16);
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
#[expected_failure(abort_code = marker::EPauseUnchanged, location = blast_presale::blast_presale_package)]
fun pausing_an_already_paused_bit_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 1);
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 1);
    abort
}

#[test]
#[expected_failure(abort_code = marker::EPauseUnchanged, location = blast_presale::blast_presale_package)]
fun unpausing_an_already_clear_bit_is_rejected() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 1);
    abort
}

#[test]
fun every_disjoint_u8_query_is_allowed_in_every_reachable_state() {
    vector[0u64, 1, 2, 3, 8, 9, 10, 11].do!(|initial| {
        let version = version_in_state(initial as u8);
        256u64.do!(|query| {
            // An independent per-flag oracle covers zero and unsupported query bits too.
            let overlaps = vector[1u64, 2, 8].any!(
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
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_1_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(1, 1);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_1_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(1, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_1_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(1, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_1_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(1, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_2_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(2, 2);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_2_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(2, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_2_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(2, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_2_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(2, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(3, 1);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(3, 2);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(3, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(3, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(3, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_3_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(3, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_8_rejects_overlapping_mask_8() {
    assert_guard_rejects_mask(8, 8);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_8_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(8, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_8_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(8, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_8_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(8, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(9, 1);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(9, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_8() {
    assert_guard_rejects_mask(9, 8);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(9, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(9, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_9_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(9, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(10, 2);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(10, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_8() {
    assert_guard_rejects_mask(10, 8);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(10, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(10, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_10_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(10, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_1() {
    assert_guard_rejects_mask(11, 1);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_2() {
    assert_guard_rejects_mask(11, 2);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_3() {
    assert_guard_rejects_mask(11, 3);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_8() {
    assert_guard_rejects_mask(11, 8);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_9() {
    assert_guard_rejects_mask(11, 9);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_10() {
    assert_guard_rejects_mask(11, 10);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun paused_state_11_rejects_overlapping_mask_11() {
    assert_guard_rejects_mask(11, 11);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_1() {
    assert_guard_rejects_mask(1, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_2() {
    assert_guard_rejects_mask(2, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_3() {
    assert_guard_rejects_mask(3, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_8() {
    assert_guard_rejects_mask(8, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_9() {
    assert_guard_rejects_mask(9, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_10() {
    assert_guard_rejects_mask(10, 255);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_presale::blast_presale_package)]
fun unsupported_query_bits_do_not_hide_paused_state_11() {
    assert_guard_rejects_mask(11, 255);
}

// === Test Helpers ===

fun version_in_state(mask: u8): marker::PackageVersion {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    if (mask != 0) {
        version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), mask);
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
use blast_presale::{blast_presale_package as marker, blast_presale_domain::{PauseAdmin, UnpauseAdmin}};
use std::unit_test::{assert_eq, destroy};
