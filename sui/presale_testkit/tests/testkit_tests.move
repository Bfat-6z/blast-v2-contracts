// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale_testkit::testkit_tests;

// === Constants ===

const MINTER: address = @0xA11CE;

// === Tests ===

#[test]
/// Any caller mints from the shared faucet.
fun the_faucet_mints_for_anyone() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut registry = coin_registry::create_coin_data_registry_for_testing(scenario.ctx());
    test_sui::create(&mut registry, scenario.ctx());

    scenario.next_tx(MINTER);
    let mut faucet = scenario.take_shared<Faucet>();
    let coin = faucet.mint(1_000_000_000, scenario.ctx());

    assert_eq!(coin.value(), 1_000_000_000);

    destroy(coin);
    test_scenario::return_shared(faucet);
    destroy(registry);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = coin_registry::ECurrencyAlreadyExists, location = coin_registry)]
/// TEST_SUI registers once.
fun test_sui_registers_once() {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);

    test_sui::create(&mut registry, &mut ctx);
    test_sui::create(&mut registry, &mut ctx);
    abort
}

// === Imports ===

use blast_presale_testkit::test_sui::{Self, Faucet};

use std::unit_test::{assert_eq, destroy};

use sui::{coin_registry, test_scenario};
