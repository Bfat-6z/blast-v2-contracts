// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide core constants exposed as zero-cost macros.
module blast_core::constants;

// === Package Constants ===

/// Denominator for rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Maximum routes in one fee split: 16 address routes plus one of each of the four special kinds.
/// Every collection pays them in the same transaction.
macro public(package) fun max_routes(): u64 {
    20
}

/// A technical bound on a vesting schedule's duration: from any clock below 2^63 ms, about 292
/// million years, the schedule's end still fits in u64, so payout cannot overflow creating it.
macro public(package) fun max_vesting_duration_ms(): u64 {
    1 << 63
}

/// Byte length of a Blake2b-256 digest: Merkle roots, leaves, and proof siblings.
macro public(package) fun digest_length(): u64 {
    32
}

/// Notice every treasury change waits from publication: the genesis destination is compiled, so
/// no setup needs a zero notice.
macro public(package) fun initial_treasury_delay_ms(): u64 {
    48 * 60 * 60 * 1_000
}
