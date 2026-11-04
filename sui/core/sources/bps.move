// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the rate's abort location.
#[allow(lint(abort_without_constant))]
/// Validated basis-points rates, their rounded application, and the one exact apportionment every
/// Blast split uses.
module blast_core::bps;

// === Public Types ===

/// A rate from zero through 10,000 basis points; `new` is the only way to build one.
public struct Bps(u64) has copy, drop, store;

// === Public Functions ===

public fun new(value: u64): Bps {
    assert!(value <= constants::basis_points_denominator!(), blast_core::errors::invalid_bps!());

    Bps(value)
}

public fun value(self: Bps): u64 {
    let Bps(value) = self;

    value
}

/// Applies the rate to `amount`, rounding up; the result is at most `amount`.
public fun apply_up(self: Bps, amount: u64): u64 {
    amount.mul_div_ceil(self.value(), constants::basis_points_denominator!())
}

/// Largest-remainder apportionment of `total` over `rates`, which must sum to exactly 10,000: the
/// `rounded_up` part takes its ceiling, every other part its floor, and the leftover units go one
/// each to the largest remaining remainders, earlier parts first. The amounts sum to `total`.
public fun apportion(rates: vector<Bps>, total: u64, rounded_up: Option<u64>): vector<u64> {
    assert!(
        total(&rates) == constants::basis_points_denominator!()
            && rounded_up.is_none_or!(|index| *index < rates.length()),
        blast_core::errors::invalid_apportionment!(),
    );

    let denominator = constants::basis_points_denominator!() as u128;
    let products = rates.map!(|rate| (total as u128) * (rate.value() as u128));
    let mut amounts = vector::tabulate!(products.length(), |i| {
        if (rounded_up.contains(&i)) products[i].div_ceil(denominator) as u64
        else (products[i] / denominator) as u64
    });

    let mut order = vector::tabulate!(products.length(), |i| i)
        .filter!(|i| !rounded_up.contains(i));
    order.insertion_sort_by!(|a, b| {
        let (remainder_a, remainder_b) = (products[*a] % denominator, products[*b] % denominator);
        remainder_a > remainder_b || (remainder_a == remainder_b && *a <= *b)
    });

    let leftover = total - amounts.fold!(0, |sum, amount| sum + amount);
    leftover.do!(|i| *&mut amounts[order[i]] = amounts[order[i]] + 1);

    amounts
}

// === Package Functions ===

/// The sum of `rates`, which may exceed 10,000.
public(package) fun total(rates: &vector<Bps>): u64 {
    (*rates).fold!(0, |sum, rate| sum + rate.value())
}

// === Imports ===

use blast_core::constants;
