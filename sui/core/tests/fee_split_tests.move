// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::fee_split_tests;

// === Tests ===

#[test]
fun every_destination_kind_composes_one_exact_split() {
    let split = fee_split::new(vector[
        fee_split::route(fee_split::to_owner(), bps::new(4_000)),
        fee_split::route(fee_split::to_auto_lp(), bps::new(2_000)),
        fee_split::route(fee_split::to_holder_rewards(), bps::new(2_000)),
        fee_split::route(fee_split::to_burn(), bps::new(1_000)),
        fee_split::route(fee_split::to_address(@0xA), bps::new(1_000)),
    ]);

    assert_eq!(split.apportion(1_001), vector[401, 200, 200, 100, 100]);
    assert!(split.has(fee_split::to_burn()) && !split.has(fee_split::to_address(@0xB)));
    let routes = split.routes();
    assert!(routes[0].destination().is_owner() && routes[1].destination().is_auto_lp());
    assert!(routes[2].destination().is_holder_rewards() && routes[3].destination().is_burn());
    assert_eq!(routes[4].destination().address_of(), option::some(@0xA));
    assert_eq!(routes[0].destination().address_of(), option::none());
    assert_eq!(routes[4].bps(), bps::new(1_000));
}

#[test]
fun the_largest_split_has_sixteen_address_routes() {
    let routes = vector::tabulate!(16, |i| {
        fee_split::route(fee_split::to_address(sui::address::from_u256((i + 1) as u256)), bps::new(625))
    });
    let amounts = fee_split::new(routes).apportion(16);
    assert!(amounts.all!(|amount| *amount == 1));
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidRoute, location = blast_core::fee_split)]
fun a_route_rejects_the_zero_address() {
    fee_split::to_address(@0x0);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidRoute, location = blast_core::fee_split)]
fun a_route_rejects_a_zero_share() {
    fee_split::route(fee_split::to_owner(), bps::new(0));
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidFeeSplit, location = blast_core::fee_split)]
fun a_split_rejects_a_repeated_special_kind() {
    fee_split::new(vector[
        fee_split::route(fee_split::to_owner(), bps::new(5_000)),
        fee_split::route(fee_split::to_owner(), bps::new(5_000)),
    ]);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidFeeSplit, location = blast_core::fee_split)]
fun a_split_rejects_a_repeated_address() {
    fee_split::new(vector[
        fee_split::route(fee_split::to_address(@0xA), bps::new(5_000)),
        fee_split::route(fee_split::to_address(@0xA), bps::new(5_000)),
    ]);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidFeeSplit, location = blast_core::fee_split)]
fun a_split_rejects_a_total_below_the_whole() {
    fee_split::new(vector[fee_split::route(fee_split::to_owner(), bps::new(9_999))]);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidFeeSplit, location = blast_core::fee_split)]
fun a_split_rejects_the_first_route_over_capacity() {
    let mut routes = vector::tabulate!(16, |i| {
        fee_split::route(fee_split::to_address(sui::address::from_u256((i + 1) as u256)), bps::new(600))
    });
    routes.push_back(fee_split::route(fee_split::to_owner(), bps::new(400)));
    fee_split::new(routes);
}

// === Imports ===

use blast_core::{bps, fee_split};

use std::unit_test::assert_eq;
