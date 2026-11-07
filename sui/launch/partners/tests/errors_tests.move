// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_partners::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_recipient!(),
        errors::share_above_max!(),
        errors::unchanged!(),
        errors::not_live_cap!(),
        errors::partner_not_accepted!(),
    ];
    assert_eq!(codes.length(), 5);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_partners::errors;

use std::unit_test::assert_eq;
