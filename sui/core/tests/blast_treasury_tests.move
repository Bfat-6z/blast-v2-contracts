// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::blast_treasury_tests;

// === Constants ===

const GENESIS: address = @0x7EA5;
const NEXT: address = @0x7EA6;
const NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

// === Tests ===

#[test]
fun a_new_destination_waits_the_applied_notice_and_anyone_applies_it() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    let mut treasury = blast_treasury::new_for_testing(GENESIS, ctx);
    assert!(treasury.is_guarded());

    treasury.schedule_destination(&blast_acl::witness_for_testing<TreasuryAdmin>(), NEXT, NOTICE_MS, &clock);
    assert_eq!(treasury.destination(), GENESIS);

    clock.increment_for_testing(NOTICE_MS);
    treasury.apply_destination(&clock);
    assert_eq!(treasury.destination(), NEXT);

    destroy(treasury);
    destroy(clock);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_destination_cannot_apply_before_its_notice() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    let mut treasury = blast_treasury::new_for_testing(GENESIS, ctx);
    treasury.schedule_destination(&blast_acl::witness_for_testing<TreasuryAdmin>(), NEXT, NOTICE_MS, &clock);

    clock.increment_for_testing(NOTICE_MS - 1);
    treasury.apply_destination(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun a_cancelled_destination_cannot_apply() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    let mut treasury = blast_treasury::new_for_testing(GENESIS, ctx);
    treasury.schedule_destination(&blast_acl::witness_for_testing<TreasuryAdmin>(), NEXT, NOTICE_MS, &clock);
    treasury.cancel_destination(&blast_acl::witness_for_testing<CancelAdmin>());

    clock.increment_for_testing(NOTICE_MS);
    treasury.apply_destination(&clock);

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidTreasury, location = blast_core::blast_treasury)]
fun a_destination_must_be_a_nonzero_address() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut treasury = blast_treasury::new_for_testing(GENESIS, ctx);

    treasury.schedule_destination(&blast_acl::witness_for_testing<TreasuryAdmin>(), @0x0, NOTICE_MS, &clock);

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidTreasury, location = blast_core::blast_treasury)]
fun the_genesis_destination_must_be_set() {
    blast_treasury::new_for_testing(@0x0, &mut tx_context::dummy()).share_for_testing();
}

// === Imports ===

use blast_admin::blast_acl;

use blast_core::{blast_domain::{CancelAdmin, TreasuryAdmin}, blast_treasury};

use std::unit_test::{assert_eq, destroy};

use sui::clock;
