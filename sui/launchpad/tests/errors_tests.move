// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::errors_tests;

// === Tests ===

#[test]
/// Pins every launchpad abort code; pause, version, and upgrade aborts are `blast_admin`'s and
/// fee-payout aborts are `blast_core`'s.
fun error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_trade_fee_bps!(), 0);
    assert_eq!(blast_fun::errors::decimals_not_allowed!(), 1);
    assert_eq!(blast_fun::errors::venue_not_allowed!(), 2);
    assert_eq!(blast_fun::errors::invalid_venue!(), 3);
    assert_eq!(blast_fun::errors::invalid_protocol_allocation!(), 4);
    assert_eq!(blast_fun::errors::invalid_shares!(), 5);
    assert_eq!(blast_fun::errors::recipient_capacity_reached!(), 6);
    assert_eq!(blast_fun::errors::invalid_sell_burn_bps!(), 7);
    assert_eq!(blast_fun::errors::invalid_initial_meme_supply!(), 8);
    assert_eq!(blast_fun::errors::invalid_meme_quote_pair!(), 9);
    assert_eq!(blast_fun::errors::invalid_opening_round!(), 10);
    assert_eq!(blast_fun::errors::invalid_graduation_target!(), 11);
    assert_eq!(blast_fun::errors::invalid_launch_lifecycle!(), 12);
    assert_eq!(blast_fun::errors::slippage_exceeded!(), 13);
    assert_eq!(blast_fun::errors::zero_trade_output!(), 14);
    assert_eq!(blast_fun::errors::opening_round_ended!(), 15);
    assert_eq!(blast_fun::errors::opening_round_not_ended!(), 16);
    assert_eq!(blast_fun::errors::nothing_accrued!(), 17);
    assert_eq!(blast_fun::errors::creator_cap_not_live!(), 18);
    assert_eq!(blast_fun::errors::unchanged!(), 19);
    assert_eq!(blast_fun::errors::invalid_creator_recipient!(), 20);
    assert_eq!(blast_fun::errors::invalid_account_commitment!(), 21);
    assert_eq!(blast_fun::errors::invalid_creator_claim_public_key!(), 22);
    assert_eq!(blast_fun::errors::invalid_creator_claim_attestation!(), 23);
    assert_eq!(blast_fun::errors::creator_claim_expired!(), 24);
    assert_eq!(blast_fun::errors::creator_not_sender!(), 25);
    assert_eq!(blast_fun::errors::invalid_creator_claim_signature!(), 26);
    assert_eq!(blast_fun::errors::quote_not_allowed!(), 27);
    assert_eq!(blast_fun::errors::invalid_virtual_quote!(), 28);
    assert_eq!(blast_fun::errors::zero_opening_round_bid!(), 29);
    assert_eq!(blast_fun::errors::invalid_creation_fee!(), 30);
    assert_eq!(blast_fun::errors::too_many_claim_signers!(), 31);
    assert_eq!(blast_fun::errors::unguarded_delay!(), 32);
    assert_eq!(blast_fun::errors::invalid_protocol_fee_share!(), 33);
    assert_eq!(blast_fun::errors::invalid_lp_fee_bps!(), 34);
}

// === Imports ===

use std::unit_test::assert_eq;
