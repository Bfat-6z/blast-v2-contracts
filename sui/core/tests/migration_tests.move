// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::migration_tests;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

public struct VenueWitness() has drop;

public struct OtherVenueWitness() has drop;

public struct TestPackageWitness() has drop;

public struct OtherPackageWitness() has drop;

// === Tests ===

#[test]
fun a_ticket_names_its_venue() {
    let venue = migration::issue_ticket(VenueWitness()).redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<VenueWitness>());
}

#[test]
fun the_stored_venue_redeems_the_balances_and_terms() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, terms) = migration.redeem(VenueWitness());

    assert_eq!(meme.value(), 100);
    assert_eq!(quote.value(), 200);
    assert_eq!(terms.origin(), sale_id());
    assert_eq!(terms.package_witness(), type_name::with_original_ids<TestPackageWitness>());
    let (meme_share, quote_share) = terms.protocol_bps();
    assert!(meme_share == bps::new(1_500) && quote_share == bps::new(1_000));
    assert_eq!(terms.partner_id(), option::none());
    assert!(terms.has_protocol_residuals());
    assert!(terms.fee_split().routes()[0].destination().is_owner());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun another_venue_cannot_redeem_the_migration() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, _) = migration.redeem(OtherVenueWitness());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongPackageWitness,
    location = blast_core::migration,
)]
fun a_package_cannot_migrate_with_another_packages_terms() {
    let migration = migration::new(
        OtherPackageWitness(),
        balance::create_for_testing<MEME>(1),
        balance::create_for_testing<QUOTE>(1),
        type_name::with_original_ids<VenueWitness>(),
        sale_terms(),
    );

    destroy(migration);
}

#[test]
/// A standalone issuer seals terms without a hand-off and issues the owner proofs for them.
fun standalone_terms_verify_owner_proofs_from_their_issuer() {
    let terms = migration::vault_terms(
        OtherPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(0),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
    assert!(!terms.has_protocol_residuals());

    owner_proof::new(OtherPackageWitness(), sale_id()).assert_terms(&terms);
}

#[test]
fun the_sale_owner_proof_verifies_against_its_vault_terms() {
    let terms = sale_terms();

    owner_proof::new(TestPackageWitness(), sale_id()).assert_terms(&terms);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_package_cannot_prove_ownership() {
    owner_proof::new(OtherPackageWitness(), sale_id()).assert_terms(&sale_terms());
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_sale_cannot_prove_ownership() {
    let other_sale = object::id_from_address(@0xB0B);
    owner_proof::new(TestPackageWitness(), other_sale).assert_terms(&sale_terms());
}

// === Test Helpers ===

fun sale_id(): ID { object::id_from_address(@0x5A1E) }

fun owner_split(): fee_split::FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

fun sale_terms(): VaultTerms {
    migration::vault_terms(
        TestPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(1_500),
        bps::new(1_000),
        option::none(),
        migration::residuals_to_protocol(),
    )
}

fun new_migration(venue: type_name::TypeName): Migration<MEME, QUOTE> {
    migration::new(
        TestPackageWitness(),
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(200),
        venue,
        sale_terms(),
    )
}

// === Imports ===

use blast_core::{bps, fee_split, migration::{Self, Migration, VaultTerms}, owner_proof};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::balance;
