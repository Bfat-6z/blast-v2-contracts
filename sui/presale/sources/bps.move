// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Validated basis-points values and explicit rounded application.
module blast_presale::bps;

// === Public Types ===

/// A rate from zero through 10,000 basis points; `new` is the only way to build one.
public struct Bps(u64) has copy, drop, store;

// === Public Functions ===

public fun new(value: u64): Bps {
    assert!(value <= constants::basis_points_denominator!(), blast_presale::errors::invalid_bps!());

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

// === Imports ===

use blast_presale::constants;
