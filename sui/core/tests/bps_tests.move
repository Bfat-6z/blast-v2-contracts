// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::bps_tests;

// === Tests ===

#[test]
fun constructor_accepts_the_complete_closed_range() {
    assert_eq!(bps::new(0).value(), 0);
    assert_eq!(bps::new(10_000).value(), 10_000);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidBps, location = blast_core::bps)]
fun constructor_rejects_the_first_value_above_one_hundred_percent() {
    bps::new(10_001);
}

#[test]
fun upward_application_assigns_the_remainder_to_the_rate() {
    assert_eq!(bps::new(2_500).apply_up(10_001), 2_501);
    assert_eq!(bps::new(10_000).apply_up(std::u64::max_value!()), std::u64::max_value!());
    assert_eq!(bps::new(0).apply_up(10_001), 0);
}

#[test]
fun apportionment_assigns_every_unit_and_leftovers_to_the_largest_remainders() {
    // 1/3 each of 10 units: floors 3/3/3, one leftover to the earliest of the equal remainders.
    assert_eq!(apportion_rates(vector[3_334, 3_333, 3_333], 10, option::none()), vector[4, 3, 3]);
    // The rounded-up part takes its ceiling; the others share what is left.
    assert_eq!(apportion_rates(vector[3_333, 3_333, 3_334], 10, option::some(0)), vector[4, 3, 3]);
    assert_eq!(apportion_rates(vector[10_000], 7, option::some(0)), vector[7]);
    assert_eq!(apportion_rates(vector[5_000, 5_000], 0, option::none()), vector[0, 0]);
}

#[test]
fun apportionment_preserves_the_total_for_every_rounded_up_choice() {
    let rates = vector[1, 2_499, 2_500, 4_999, 1];
    vector[0u64, 1, 9, 9_999, 10_001, 123_456_789, std::u64::max_value!()].do!(|total| {
        let mut choice = 0;
        while (choice <= rates.length()) {
            let rounded_up = if (choice == rates.length()) option::none() else option::some(choice);
            let amounts = apportion_rates(rates, total, rounded_up);
            assert_eq!(amounts.fold!(0u128, |sum, amount| sum + (amount as u128)), total as u128);
            rounded_up.do!(|index| {
                assert_eq!(amounts[index], bps::new(rates[index]).apply_up(total));
            });
            choice = choice + 1;
        };
    });
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidApportionment,
    location = blast_core::bps,
)]
fun apportionment_rejects_rates_below_the_whole() {
    apportion_rates(vector[5_000, 4_999], 10, option::none());
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EInvalidApportionment,
    location = blast_core::bps,
)]
fun apportionment_rejects_a_rounded_up_index_outside_the_rates() {
    apportion_rates(vector[10_000], 10, option::some(1));
}

// === Test Helpers ===

fun apportion_rates(rates: vector<u64>, total: u64, rounded_up: Option<u64>): vector<u64> {
    bps::apportion(rates.map!(|rate| bps::new(rate)), total, rounded_up)
}

// === Imports ===

use blast_core::bps;

use std::unit_test::assert_eq;
