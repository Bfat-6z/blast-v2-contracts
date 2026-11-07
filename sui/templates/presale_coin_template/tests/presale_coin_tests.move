// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module presale_coin_template::presale_coin_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PUBLISHER: address = @0xA11CE;

/// The template constants `init` passes, as the generated module declares them.
const TEMPLATE_DECIMALS: u8 = 9;

const TEMPLATE_METADATA_CAP_RECIPIENT: address = @0x3e7a;

// === Tests ===

#[test]
fun init_delivers_a_sealed_cap_and_the_template_metadata() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    presale_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    let currency = scenario.take_from_address<Currency<PRESALE_COIN>>(COIN_REGISTRY);
    assert_eq!(currency.decimals(), TEMPLATE_DECIMALS);
    assert_eq!(currency.symbol(), b"SALE".to_string());
    assert_eq!(currency.name(), b"Blast Sale Token".to_string());
    assert_eq!(currency.description(), b"A token sold on Blast".to_string());
    assert_eq!(currency.icon_url(), b"https://blast.fun/sale.png".to_string());
    assert!(currency.total_supply().is_none());
    assert!(!test_scenario::has_most_recent_for_address<TreasuryCap<PRESALE_COIN>>(PUBLISHER));

    let sealed_treasury_cap = scenario.take_from_sender<SealedTreasuryCap<PRESALE_COIN>>();
    assert_eq!(sealed_treasury_cap.package_witness(), type_name::with_original_ids<PackageWitness>());
    assert_eq!(sealed_treasury_cap.total_supply(), 0);
    let metadata_cap =
        scenario.take_from_address<MetadataCap<PRESALE_COIN>>(TEMPLATE_METADATA_CAP_RECIPIENT);
    assert_eq!(currency.metadata_cap_id(), option::some(object::id(&metadata_cap)));

    destroy(sealed_treasury_cap);
    destroy(metadata_cap);
    destroy(currency);
    scenario.end();
}

// === Imports ===

use blast_core::sealed_treasury_cap::SealedTreasuryCap;

use blast_presale::blast_presale_package::PackageWitness;

use presale_coin_template::presale_coin::{Self, PRESALE_COIN};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{coin::TreasuryCap, coin_registry::{Currency, MetadataCap}, test_scenario};
