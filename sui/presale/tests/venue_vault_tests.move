// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The hand-off at each presale venue: the vault a venue creates carries the sale's terms, its
/// residuals wait for the owner, only the sale's venue redeems the hand-off, and only the sale's
/// creator capability proves ownership of the sale's vault.
module blast_presale::venue_vault_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated sale token's.
public struct VENUE_VAULT_TESTS() has drop;

// === Tests ===

#[test]
/// A Cetus migration's vault starts with the sale's split and Blast's snapshotted LP-fee rates,
/// and holds the hand-off it was given for the sale's owner, who claims it with an owner proof.
fun a_cetus_vault_carries_the_sales_terms_and_owner_residuals() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(VENUE_VAULT_TESTS());
    let (sale_id, cap) = fixture.fund_cetus_sale(treasury_cap, &mut currency, owner_split());

    let vault_id = fixture.migrate_with_cetus<VENUE_VAULT_TESTS>(sale_id);

    fixture.assert_vault_holds_the_sales_terms(vault_id);
    assert_eq!(
        fixture.claim_owner_balances<VENUE_VAULT_TESTS, VENUE_VAULT_TESTS>(sale_id, vault_id, &cap),
        vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()],
    );

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
/// A Bluefin migration's vault carries the sale's terms and owner residuals the same way.
fun a_bluefin_vault_carries_the_sales_terms_and_owner_residuals() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(VENUE_VAULT_TESTS());
    let (sale_id, cap) = fixture.fund_bluefin_sale(treasury_cap, &mut currency, owner_split());

    let vault_id = fixture.migrate_with_bluefin<VENUE_VAULT_TESTS>(sale_id);

    fixture.assert_vault_holds_the_sales_terms(vault_id);
    assert_eq!(
        fixture.claim_owner_balances<VENUE_VAULT_TESTS, VENUE_VAULT_TESTS>(sale_id, vault_id, &cap),
        vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()],
    );

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
/// A sale prepared for Bluefin cannot migrate through Cetus: Cetus cannot redeem its hand-off.
fun a_sale_cannot_migrate_through_another_venue() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(VENUE_VAULT_TESTS());
    let (sale_id, _cap) = fixture.fund_bluefin_sale(treasury_cap, &mut currency, owner_split());

    fixture.migrate_with_cetus<VENUE_VAULT_TESTS>(sale_id);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EWrongPresaleCap,
    location = blast_presale::blast_presale,
)]
/// Another sale's creator capability proves nothing about this sale.
fun another_sales_cap_cannot_prove_ownership() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(VENUE_VAULT_TESTS());
    let (sale_id, _cap) = fixture.fund_bluefin_sale(treasury_cap, &mut currency, owner_split());
    let (other_treasury_cap, mut other_currency) = fixture.new_currency(
        test_utils::create_one_time_witness<VENUE_FIXTURE>(),
    );
    let (_, other_cap) = fixture.fund_bluefin_sale(
        other_treasury_cap,
        &mut other_currency,
        owner_split(),
    );
    let vault_id = fixture.migrate_with_bluefin<VENUE_VAULT_TESTS>(sale_id);

    fixture.claim_owner_balances<VENUE_VAULT_TESTS, VENUE_VAULT_TESTS>(
        sale_id,
        vault_id,
        &other_cap,
    );

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongOwner, location = blast_core::owner_proof)]
/// An owner proof for one sale does not open another sale's vault, though the same package
/// sealed both.
fun a_proof_for_one_sale_cannot_claim_another_sales_vault() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(VENUE_VAULT_TESTS());
    let (sale_id, cap) = fixture.fund_bluefin_sale(treasury_cap, &mut currency, owner_split());
    let (other_treasury_cap, mut other_currency) = fixture.new_currency(
        test_utils::create_one_time_witness<VENUE_FIXTURE>(),
    );
    let (other_sale_id, _other_cap) = fixture.fund_bluefin_sale(
        other_treasury_cap,
        &mut other_currency,
        owner_split(),
    );
    let other_vault_id = fixture.migrate_with_bluefin<VENUE_FIXTURE>(other_sale_id);

    fixture.claim_owner_balances<VENUE_VAULT_TESTS, VENUE_FIXTURE>(sale_id, other_vault_id, &cap);

    abort
}

// === Test Helpers ===

/// Half of every LP fee to the sale's owner, half to holder rewards.
fun owner_split(): FeeSplit {
    fee_split::new(vector[
        fee_split::route(fee_split::owner_destination(), bps::new(5_000)),
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(5_000)),
    ])
}

/// The vault starts with `owner_split`, Blast's snapshotted LP-fee rates, and the whole hand-off
/// as the owner's residuals.
fun assert_vault_holds_the_sales_terms(self: &mut VenueFixture, vault_id: ID) {
    let (applied_split, state) = self.vault_state<VENUE_VAULT_TESTS>(vault_id);

    assert_eq!(applied_split, owner_split());
    let mut expected = venue_fixture::lp_fee_bps();
    expected.append(vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()]);
    assert_eq!(state, expected);
}

// === Imports ===

use blast_core::{bps, fee_split::{Self, FeeSplit}};

use blast_presale::venue_fixture::{Self, VENUE_FIXTURE, VenueFixture};

use std::unit_test::{assert_eq, destroy};

use sui::test_utils;

use fun assert_vault_holds_the_sales_terms as VenueFixture.assert_vault_holds_the_sales_terms;
