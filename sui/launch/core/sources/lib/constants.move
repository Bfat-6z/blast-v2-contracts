// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Core constants exposed as zero-cost macros. The basis-points denominator, Blast's LP-fee share
/// maximum, and the bounds of core's public constructors are public, so every launch package uses
/// the one value.
module blast_core::constants;

// === Package Constants ===

/// Denominator for rates expressed in basis points.
public macro fun basis_points_denominator(): u64 {
    10_000
}

/// Blast's largest share of each asset in a vault's LP fees, in basis points. `vault_terms`
/// enforces it when a sale or issuer seals a vault's terms.
public macro fun max_lp_fee_bps(): u64 {
    3_000
}

/// Maximum routes in one fee split, so 16 recipients still fit beside the four special kinds.
/// Every collection pays them in the same transaction.
public macro fun max_routes(): u64 {
    20
}

/// A technical bound on a vesting schedule's duration: from any clock below 2^63 ms, about 292
/// million years, the schedule's end still fits in u64, so payout cannot overflow creating it.
public macro fun max_vesting_duration_ms(): u64 {
    1 << 63
}

/// Byte length of a Blake2b-256 digest: Merkle roots, leaves, and proof siblings.
macro public(package) fun digest_length(): u64 {
    32
}

/// The lowest sqrt price, Q64.64, the Cetus and Bluefin `tick_math` modules accept.
macro public(package) fun min_sqrt_price_x64(): u128 {
    4_295_048_016
}

/// The highest sqrt price, Q64.64, the Cetus and Bluefin `tick_math` modules accept.
macro public(package) fun max_sqrt_price_x64(): u128 {
    79_226_673_515_401_279_992_447_579_055
}

/// The delay every treasury change waits from publication: the genesis destination is compiled,
/// so no setup needs a zero delay.
macro public(package) fun initial_treasury_delay_ms(): u64 {
    48 * 60 * 60 * 1_000
}
