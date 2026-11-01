// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_admin::delayed_tests;

// === Tests ===

#[test]
fun reads_stay_applied_until_an_explicit_apply_at_the_boundary() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    clock.set_for_testing(10);
    let mut setting = delayed::new(7u64);
    assert_eq!(setting.schedule(9, &clock), 172_800_010);
    assert_eq!(setting.value(), 7);
    clock.set_for_testing(172_800_010);
    assert_eq!(setting.value(), 7);
    assert_eq!(setting.apply(&clock), 9);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun one_millisecond_before_ready_is_rejected() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, &clock);
    clock.set_for_testing(172_799_999);
    setting.apply(&clock);
    abort
}

#[test]
#[expected_failure(abort_code = delayed::ENotReady, location = blast_admin::delayed)]
fun replacing_a_ready_proposal_restarts_the_entire_delay() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, &clock);
    clock.set_for_testing(172_800_000);
    setting.schedule(2, &clock);
    setting.apply(&clock);
    abort
}

#[test]
fun cancellation_after_readiness_preserves_the_applied_value() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(3u64);
    setting.schedule(5, &clock);
    clock.set_for_testing(172_800_001);
    assert_eq!(setting.cancel(), 5);
    assert_eq!(setting.value(), 3);
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = delayed::ENoPending, location = blast_admin::delayed)]
fun an_applied_proposal_cannot_be_replayed() {
    let mut clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(0u64);
    setting.schedule(1, &clock);
    clock.set_for_testing(172_800_000);
    setting.apply(&clock);
    setting.apply(&clock);
    abort
}

#[test]
fun immediate_revocation_discards_a_pending_replacement() {
    let clock = clock::create_for_testing(&mut tx_context::dummy());
    let mut setting = delayed::new(vector[1u8]);
    setting.schedule(vector[2u8], &clock);
    setting.set_now(vector[]);
    assert!(setting.value().is_empty());
    assert!(!setting.pending().is_some());
    setting.destroy_for_testing();
    clock.destroy_for_testing();
}

// === Imports ===

use blast_admin::delayed;
use std::unit_test::assert_eq;
use sui::clock;
