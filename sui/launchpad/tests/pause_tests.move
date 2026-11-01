// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::pause_tests;

// === Tests ===

#[test]
fun pause_sets_only_requested_bits_and_unpause_clears_only_requested_bits() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::create_pause_bit!() | constants::trading_pause_bit!());
    version.assert_not_paused(constants::migration_pause_bit!());
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::create_pause_bit!());
    version.assert_not_paused(constants::create_pause_bit!());
    let paused = sui::event::events_by_type<blast_fun::blast_events::Event<blast_fun::events::Paused>>();
    assert_eq!(std::bcs::to_bytes(&paused[0]), vector[3u8, 3u8]);
    let unpaused = sui::event::events_by_type<blast_fun::blast_events::Event<blast_fun::events::Unpaused>>();
    assert_eq!(std::bcs::to_bytes(&unpaused[0]), vector[1u8, 2u8]);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPaused, location = blast_fun::blast_fun)]
fun clearing_create_does_not_unpause_trading() {
    let mut version = marker::new_for_testing(&mut tx_context::dummy());
    version.pause(&blast_acl::witness_for_testing<PauseAdmin>(), constants::create_pause_bit!() | constants::trading_pause_bit!());
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::create_pause_bit!());
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
    version.unpause(&blast_acl::witness_for_testing<UnpauseAdmin>(), constants::create_pause_bit!());
    abort
}

// === Imports ===

use blast_admin::blast_acl;
use blast_fun::{blast_fun as marker, blast_fun_domain::{PauseAdmin, UnpauseAdmin}, constants};
use std::unit_test::{assert_eq, destroy};
