// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::errors_tests;

// === Tests ===

#[test]
/// Pins every registry code to its position, so a reorder or gap fails here first.
fun error_registry_is_stable() {
    let codes = vector[
        errors::invalid_bps!(),
        errors::invalid_apportionment!(),
        errors::invalid_vesting_terms!(),
        errors::invalid_recipient!(),
        errors::invalid_recipients!(),
        errors::invalid_route!(),
        errors::invalid_fee_split!(),
        errors::invalid_treasury!(),
        errors::invalid_pair!(),
        errors::partner_mismatch!(),
        errors::wrong_venue!(),
        errors::wrong_owner!(),
    ];
    assert_eq!(codes.length(), 12);
    codes.length().do!(|i| assert_eq!(codes[i], i));
}

// === Imports ===

use blast_core::errors;

use std::unit_test::assert_eq;
