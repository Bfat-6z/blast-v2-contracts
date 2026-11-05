// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::sealed_treasury_cap_tests;

// === Test-Only Types ===

public struct COIN() has drop;

public struct OtherVenue() has drop;

// === Tests ===

#[test]
fun a_seal_names_its_package_witness_and_opens_under_it() {
    let mut ctx = tx_context::dummy();
    let sealed = sealed_treasury_cap::new(migration::test_issuer(), coin::create_treasury_cap_for_testing<COIN>(&mut ctx), &mut ctx);

    assert_eq!(sealed.package_witness(), type_name::with_original_ids<TestIssuer>());
    assert_eq!(sealed.total_supply(), 0);
    let treasury_cap_id = sealed.treasury_cap_id();

    let treasury_cap = sealed.into_treasury_cap(migration::test_issuer());
    assert_eq!(object::id(&treasury_cap), treasury_cap_id);
    assert_eq!(treasury_cap.total_supply(), 0);
    destroy(treasury_cap);
}

#[test]
fun an_admission_names_its_issuer_and_venue() {
    let admission = sealed_treasury_cap::venue_admission<TestVenue, _>(migration::test_issuer());

    assert_eq!(admission.package_witness(), type_name::with_original_ids<TestIssuer>());
    assert_eq!(admission.venue(), type_name::with_original_ids<TestVenue>());
}

#[test]
fun an_admitted_venue_borrows_the_cap() {
    let mut ctx = tx_context::dummy();
    let mut sealed = sealed_treasury_cap::new(migration::test_issuer(), coin::create_treasury_cap_for_testing<COIN>(&mut ctx), &mut ctx);
    let admission = sealed_treasury_cap::venue_admission<TestVenue, _>(migration::test_issuer());

    let minted = sealed.treasury_cap_mut(admission, migration::test_venue()).mint_balance(7);

    assert_eq!(sealed.total_supply(), 7);
    destroy(minted);
    destroy(sealed.into_treasury_cap(migration::test_issuer()));
}

#[test, expected_failure(abort_code = blast_core::errors::EWrongPackageWitness, location = blast_core::sealed_treasury_cap)]
fun a_venue_cannot_borrow_with_another_products_admission() {
    let mut ctx = tx_context::dummy();
    let mut sealed = sealed_treasury_cap::new(migration::test_issuer(), coin::create_treasury_cap_for_testing<COIN>(&mut ctx), &mut ctx);
    let admission = sealed_treasury_cap::venue_admission<TestVenue, _>(OtherVenue());

    destroy(sealed.treasury_cap_mut(admission, migration::test_venue()).mint_balance(1));
    abort
}

#[test, expected_failure(abort_code = blast_core::errors::EVenueNotAdmitted, location = blast_core::sealed_treasury_cap)]
fun a_venue_cannot_borrow_with_another_venues_admission() {
    let mut ctx = tx_context::dummy();
    let mut sealed = sealed_treasury_cap::new(migration::test_issuer(), coin::create_treasury_cap_for_testing<COIN>(&mut ctx), &mut ctx);
    let admission = sealed_treasury_cap::venue_admission<TestVenue, _>(migration::test_issuer());

    destroy(sealed.treasury_cap_mut(admission, OtherVenue()).mint_balance(1));
    abort
}

#[test, expected_failure(abort_code = blast_core::errors::EWrongPackageWitness, location = blast_core::sealed_treasury_cap)]
fun only_the_sealing_product_opens_the_seal() {
    let mut ctx = tx_context::dummy();
    let sealed = sealed_treasury_cap::new(migration::test_issuer(), coin::create_treasury_cap_for_testing<COIN>(&mut ctx), &mut ctx);

    destroy(sealed.into_treasury_cap(OtherVenue()));
    abort
}

// === Imports ===

use blast_core::{migration::{Self, TestIssuer, TestVenue}, sealed_treasury_cap};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::coin;
