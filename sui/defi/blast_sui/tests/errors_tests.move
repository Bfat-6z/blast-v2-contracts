// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::errors_tests;

// === Tests ===

#[test]
fun shared_error_codes_are_stable() {
    assert_eq!(errors::zero_amount!(), 0);
    assert_eq!(errors::invalid_share_amount!(), 1);
    assert_eq!(errors::zero_blast_shares!(), 2);
    assert_eq!(errors::zero_sui_redemption!(), 3);
    assert_eq!(errors::invalid_package_publisher!(), 4);
    assert_eq!(errors::unwind_only!(), 5);
    assert_eq!(errors::validator_not_active!(), 6);
    assert_eq!(errors::nonzero_initial_supply!(), 7);
    assert_eq!(errors::slippage_exceeded!(), 8);
    assert_eq!(errors::insufficient_native_redemption!(), 9);
    assert_eq!(errors::blast_assets_depleted!(), 10);
    assert_eq!(errors::bootstrap_below_native_minimum!(), 11);
    assert_eq!(errors::redeem_fee_above_maximum!(), 12);
    assert_eq!(errors::redeem_fee_unchanged!(), 13);
    assert_eq!(errors::fun_backing_below_supply!(), 14);
    assert_eq!(errors::stale_exchange_rate!(), 15);
    assert_eq!(errors::blast_deposit_below_native_minimum!(), 16);
    assert_eq!(errors::blast_deposit_not_active!(), 17);
    assert_eq!(errors::wrong_receipt_vault!(), 18);
    assert_eq!(errors::wrong_receipt_pool!(), 19);
    assert_eq!(errors::zero_sui_after_fee!(), 20);
    assert_eq!(errors::wrong_delegation_pool!(), 21);
    assert_eq!(errors::missing_package_capability!(), 22);
    assert_eq!(errors::package_capability_already_exists!(), 23);
}

// === Imports ===

use blast_sui::errors;
use std::unit_test::assert_eq;
