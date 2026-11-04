// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_bps!(),
        errors::invalid_pause_bits!(),
        errors::pause_unchanged!(),
        errors::paused!(),
        errors::wrong_upgrade_action!(),
        errors::invalid_digest!(),
        errors::unguarded_notice!(),
        errors::allowance_unchanged!(),
        errors::quote_not_allowed!(),
        errors::migration_witness_not_allowed!(),
        errors::invalid_migration_witness!(),
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
        errors::invalid_fee_split!(),
        errors::wrong_migration_witness!(),
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
        errors::no_migration_residuals!(),
        errors::zero_liquidity!(),
        errors::invalid_commitment!(),
        errors::invalid_leaf_count!(),
        errors::empty_budget!(),
        errors::empty_interval!(),
        errors::budget_overflow!(),
        errors::zero_treasury!(),
        errors::zero_claim_window!(),
        errors::wrong_round_proposal!(),
        errors::gas_reserve_too_large!(),
        errors::meme_rewards_unsupported!(),
        errors::wrong_round!(),
        errors::overlapping_interval!(),
        errors::invalid_index!(),
        errors::already_claimed!(),
        errors::invalid_beneficiary!(),
        errors::invalid_proof!(),
        errors::wrong_vault!(),
        errors::claims_still_open!(),
        errors::empty_claim!(),
        errors::insufficient_budget!(),
        errors::reserve_settled!(),
        errors::over_reserve!(),
        errors::treasury_changed!(),
        errors::claim_deadline_overflow!(),
        errors::claims_closed!(),
        errors::invalid_coin_order!(),
        errors::position_pool_mismatch!(),
        errors::wrong_coin_pair!(),
        errors::invalid_tier!(),
        errors::symbol_too_long!(),
        errors::pool_mismatch!(),
        errors::dao_fee_pool_mismatch!(),
        errors::wrong_presale!(),
        errors::invalid_dao_fee!(),
        errors::not_aftermath_vault!(),
    ];
    assert_eq!(codes.length(), 89);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_presale::errors;

use std::unit_test::assert_eq;
