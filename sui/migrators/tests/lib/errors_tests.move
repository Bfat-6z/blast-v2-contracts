// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_migrators::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_coin_order!(),
        errors::position_pool_mismatch!(),
        errors::wrong_coin_pair!(),
        errors::invalid_tier!(),
        errors::symbol_too_long!(),
    ];
    assert_eq!(codes.length(), 5);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_migrators::errors;

use std::unit_test::assert_eq;
