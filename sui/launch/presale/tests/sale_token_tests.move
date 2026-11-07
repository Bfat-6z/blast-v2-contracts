// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::sale_token_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const DECIMALS: u8 = 6;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated sale-token package's.
public struct SALE_TOKEN_TESTS has drop {}

/// A droppable type that is not a one-time witness.
public struct NotAWitness() has drop;

// === Tests ===

#[test]
fun new_seals_the_fresh_cap_under_the_presale_witness() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (initializer, sealed_treasury_cap) = new_sale_token(
        test_utils::create_one_time_witness<SALE_TOKEN_TESTS>(),
        scenario.ctx(),
    );

    assert_eq!(sealed_treasury_cap.package_witness(), type_name::with_original_ids<PackageWitness>());
    assert_eq!(sealed_treasury_cap.total_supply(), 0);

    let metadata_cap = initializer.finalize(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let currency = scenario.take_from_address<Currency<SALE_TOKEN_TESTS>>(@0xc);
    assert_eq!(currency.decimals(), DECIMALS);
    assert_eq!(currency.symbol(), b"SALE".to_string());
    assert!(currency.total_supply().is_none());

    let treasury_cap = sealed_treasury_cap.into_treasury_cap(blast_presale_package::package_witness());
    assert_eq!(treasury_cap.total_supply(), 0);
    destroy(treasury_cap);
    destroy(metadata_cap);
    destroy(currency);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui::coin_registry::ENotOneTimeWitness, location = sui::coin_registry)]
fun new_rejects_a_type_that_is_not_a_one_time_witness() {
    let mut ctx = tx_context::dummy();
    let (initializer, sealed_treasury_cap) = new_sale_token(NotAWitness(), &mut ctx);

    destroy(initializer);
    destroy(sealed_treasury_cap);
}

// === Test Helpers ===

fun new_sale_token<SaleToken: drop>(
    otw: SaleToken,
    ctx: &mut TxContext,
): (CurrencyInitializer<SaleToken>, SealedTreasuryCap<SaleToken>) {
    sale_token::new(
        otw,
        DECIMALS,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"A sale token".to_string(),
        b"".to_string(),
        ctx,
    )
}

// === Imports ===

use blast_core::sealed_treasury_cap::SealedTreasuryCap;

use blast_presale::{blast_presale_package::{Self, PackageWitness}, sale_token};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{coin_registry::{Currency, CurrencyInitializer}, test_scenario, test_utils};
