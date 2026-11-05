// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::unguarded_notice!(),
        errors::allowance_unchanged!(),
        errors::quote_not_allowed!(),
        errors::venue_not_allowed!(),
        errors::invalid_venue!(),
        errors::invalid_fees!(),
        errors::invalid_asset_pair!(),
        errors::invalid_raise_target!(),
        errors::invalid_token_allocation!(),
        errors::invalid_window!(),
        errors::invalid_eligibility_policy!(),
        errors::invalid_lifecycle!(),
        errors::presale_ended!(),
        errors::presale_not_ended!(),
        errors::zero_commitment!(),
        errors::wallet_cap_exceeded!(),
        errors::participant_capacity_reached!(),
        errors::invalid_eligibility_proof!(),
        errors::wrong_eligibility_policy!(),
        errors::total_commitment_overflow!(),
        errors::no_commitment!(),
        errors::wrong_presale_cap!(),
        errors::liquidity_deadline_not_reached!(),
        errors::initial_supply_not_zero!(),
        errors::below_minimum_commitment!(),
        errors::unreachable_raise!(),
        errors::unseedable_price!(),
        errors::invalid_uncapped_phase!(),
        errors::uncapped_phase_not_open!(),
        errors::presale_filled!(),
        errors::invalid_raise_allocation!(),
        errors::presale_not_started!(),
        errors::presale_started!(),
        errors::protocol_fees_unchanged!(),
        errors::invalid_hard_cap!(),
        errors::missing_setting!(),
        errors::sale_token_not_unregulated!(),
        errors::above_fee_policy!(),
        errors::protocol_fees_increased!(),
    ];
    assert_eq!(codes.length(), 39);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_presale::errors;

use std::unit_test::assert_eq;
