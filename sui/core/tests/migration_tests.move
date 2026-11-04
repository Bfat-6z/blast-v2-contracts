// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::migration_tests;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

public struct VenueWitness() has drop;

public struct OtherVenueWitness() has drop;

public struct ProductWitness() has drop;

public struct OtherProductWitness() has drop;

// === Tests ===

#[test]
fun a_binding_names_its_venue_and_tier() {
    let (venue, tier) = migration::bind(VenueWitness(), migration::pool_tier(60, 2_500)).unbind();

    assert_eq!(venue, type_name::with_original_ids<VenueWitness>());
    assert_eq!(tier.tick_spacing(), 60);
    assert_eq!(tier.fee_rate(), 2_500);
}

#[test]
fun the_stored_venue_redeems_the_balances_and_terms() {
    let migration = open(type_name::with_original_ids<VenueWitness>());
    let (meme_amount, quote_amount) = migration.amounts();
    assert!(meme_amount == 100 && quote_amount == 200);
    assert_eq!(migration.venue(), type_name::with_original_ids<VenueWitness>());

    let (meme, quote, terms) = migration.redeem(VenueWitness());

    assert_eq!(meme.value(), 100);
    assert_eq!(quote.value(), 200);
    assert_eq!(terms.origin(), sale_id());
    assert_eq!(terms.product(), type_name::with_original_ids<ProductWitness>());
    let (meme_share, quote_share) = terms.protocol_shares();
    assert!(meme_share == bps::new(1_500) && quote_share == bps::new(1_000));
    assert_eq!(terms.partner_id(), option::none());
    assert!(terms.pays_residuals_to_protocol());
    assert!(terms.fee_split().has(fee_split::to_owner()));

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun another_venue_cannot_redeem_the_migration() {
    let (meme, quote, _) = open(type_name::with_original_ids<VenueWitness>()).redeem(OtherVenueWitness());

    destroy(meme);
    destroy(quote);
}

#[test]
fun the_sale_owner_proof_verifies_against_its_vault_terms() {
    let terms = terms();

    owner_proof::prove(ProductWitness(), sale_id()).verify(&terms);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongOwner, location = blast_core::owner_proof)]
fun another_product_cannot_prove_ownership() {
    owner_proof::prove(OtherProductWitness(), sale_id()).verify(&terms());
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongOwner, location = blast_core::owner_proof)]
fun another_sale_cannot_prove_ownership() {
    owner_proof::prove(ProductWitness(), object::id_from_address(@0xB0B)).verify(&terms());
}

// === Test Helpers ===

fun sale_id(): ID { object::id_from_address(@0x5A1E) }

fun open(venue: std::type_name::TypeName): Migration<MEME, QUOTE> {
    migration::open(
        ProductWitness(),
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(200),
        venue,
        sale_id(),
        fee_split::new(vector[fee_split::route(fee_split::to_owner(), bps::new(10_000))]),
        bps::new(1_500),
        bps::new(1_000),
        option::none(),
        migration::protocol_residuals(),
    )
}

fun terms(): VaultTerms {
    let (meme, quote, terms) = open(type_name::with_original_ids<VenueWitness>())
        .redeem(VenueWitness());
    destroy(meme);
    destroy(quote);

    terms
}

// === Imports ===

use blast_core::{bps, fee_split, migration::{Self, Migration, VaultTerms}, owner_proof};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::balance;
