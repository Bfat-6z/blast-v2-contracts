// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_pause_bits!(),
        errors::pause_unchanged!(),
        errors::paused!(),
        errors::wrong_upgrade_action!(),
        errors::invalid_digest!(),
        errors::unguarded_notice!(),
        errors::allowance_unchanged!(),
        errors::quote_not_allowed!(),
        errors::venue_not_allowed!(),
        errors::invalid_venue!(),
        errors::partner_not_accepted!(),
        errors::invalid_fees!(),
        errors::invalid_destination!(),
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
        errors::invalid_vesting_terms!(),
        errors::presale_not_started!(),
        errors::presale_started!(),
        errors::protocol_fees_unchanged!(),
        errors::wrong_partner!(),
        errors::no_partner_payout!(),
        errors::invalid_hard_cap!(),
        errors::missing_setting!(),
        errors::sale_token_not_unregulated!(),
        errors::above_fee_policy!(),
        errors::protocol_fees_increased!(),
        errors::invalid_coin_order!(),
        errors::position_pool_mismatch!(),
        errors::wrong_coin_pair!(),
        errors::invalid_tier!(),
        errors::symbol_too_long!(),
        errors::pool_mismatch!(),
        errors::dao_fee_pool_mismatch!(),
        errors::invalid_dao_fee!(),
    ];
    assert_eq!(codes.length(), 57);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_presale::errors;

use std::unit_test::assert_eq;
