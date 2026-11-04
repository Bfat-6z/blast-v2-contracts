// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_vault::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_venue!(),
        errors::unadmitted_venue!(),
        errors::unguarded_notice!(),
        errors::invalid_protocol_bps!(),
        errors::zero_liquidity!(),
        errors::wrong_venue!(),
        errors::nothing_to_claim!(),
        errors::buyback_quote_out_of_range!(),
        errors::buyback_below_minimum!(),
        errors::invalid_commitment!(),
        errors::invalid_leaf_count!(),
        errors::empty_budget!(),
        errors::empty_interval!(),
        errors::budget_overflow!(),
        errors::gas_reserve_too_large!(),
        errors::zero_treasury!(),
        errors::zero_claim_window!(),
        errors::wrong_round!(),
        errors::overlapping_interval!(),
        errors::insufficient_budget!(),
        errors::wrong_round_proposal!(),
        errors::treasury_changed!(),
        errors::claim_deadline_overflow!(),
        errors::claims_closed!(),
        errors::invalid_index!(),
        errors::already_claimed!(),
        errors::invalid_beneficiary!(),
        errors::empty_claim!(),
        errors::invalid_proof!(),
        errors::wrong_vault!(),
        errors::reserve_settled!(),
        errors::over_reserve!(),
        errors::claims_still_open!(),
    ];
    assert_eq!(codes.length(), 33);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_vault::errors;

use std::unit_test::assert_eq;
