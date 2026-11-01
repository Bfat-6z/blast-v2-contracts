// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::pause_tests;

// === Tests ===

#[test]
fun pause_sets_only_requested_bits_and_unpause_clears_only_requested_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 1 | 2);
    version.assert_not_paused(8);
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 1);
    version.assert_not_paused(1);
    let paused = sui::event::events_by_type<blast_fun::blast_events::Event<marker::Paused>>();
    assert_eq!(std::bcs::to_bytes(&paused[0]), vector[3u8, 3u8]);
    let unpaused = sui::event::events_by_type<blast_fun::blast_events::Event<marker::Unpaused>>();
    assert_eq!(std::bcs::to_bytes(&unpaused[0]), vector[1u8, 2u8]);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = marker::EPaused, location = blast_fun::blast_fun)]
fun clearing_create_does_not_unpause_buy() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), 3);
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), 1);
    version.assert_not_paused(2);
    abort
}

#[test]
#[expected_failure(abort_code = marker::EInvalidPauseBits, location = blast_fun::blast_fun)]
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

// === Imports ===

use blast_admin::blast_acl;
use blast_fun::{blast_fun as marker, blast_fun_domain::{PauseAdmin, UnpauseAdmin}};
use std::unit_test::{assert_eq, destroy};
