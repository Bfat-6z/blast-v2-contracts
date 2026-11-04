// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide presale constants exposed as zero-cost macros.
module blast_presale::constants;

// === Package Constants ===

/// Stops presale creation and sharing.
macro public(package) fun create_pause_bit(): u8 {
    1
}

/// Stops open, allowlisted, and uncapped commitments.
macro public(package) fun commit_pause_bit(): u8 {
    2
}

/// Stops LP migration.
macro public(package) fun migration_pause_bit(): u8 {
    4
}

/// Every supported presale pause flag.
macro public(package) fun valid_pause_bits(): u8 {
    blast_presale::constants::create_pause_bit!()
        | blast_presale::constants::commit_pause_bit!()
        | blast_presale::constants::migration_pause_bit!()
}

/// Denominator for rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Technical bound on the dynamic commitment records one presale may hold.
macro public(package) fun max_participants(): u64 {
    65_536
}

/// Bounds the token and raise recipient lists, both paid in the one migration transaction.
macro public(package) fun max_recipients(): u64 {
    64
}

/// Bounds the transfers one fee collection makes.
macro public(package) fun max_fee_recipients(): u64 {
    16
}

/// The shortest LP-migration window. Migration is permissionless, so a funded sale reaches its
/// refund exit only after a week in which nobody migrated it, and a sale that nobody settled by
/// its end cannot be settled and cancelled in one transaction inside that week.
macro public(package) fun min_liquidity_window_duration_ms(): u64 {
    7 * 24 * 60 * 60 * 1_000
}

/// A technical bound on a vesting schedule's duration: from any clock below 2^63 ms, about 292
/// million years, the schedule's end still fits in u64, so migration cannot overflow creating it.
macro public(package) fun max_vesting_duration_ms(): u64 {
    1 << 63
}

/// Blast's largest share of a sale's raise.
macro public(package) fun max_raise_bps(): u64 {
    1_000
}

/// Blast's largest share of a sale's tokens.
macro public(package) fun max_token_bps(): u64 {
    1_000
}

/// Blast's largest share of each LP fee, Meme and Quote.
macro public(package) fun max_lp_fee_bps(): u64 {
    3_000
}

/// The most leaves one holder-reward round may commit.
macro public(package) fun max_reward_leaves(): u64 {
    65_536
}

/// Largest holder-reward gas reserve, in basis points of the round's holder Quote.
macro public(package) fun max_gas_reserve_bps(): u64 {
    1_000
}

/// Byte length of a Blake2b-256 digest: Merkle roots and nodes.
macro public(package) fun digest_length(): u64 {
    32
}

/// Bluefin stores the pool name, built from this symbol, twice in every `Position`; the
/// bound keeps a migrated position inside Sui's object size limit (ADR 0088).
macro public(package) fun max_meme_symbol_length(): u64 {
    32
}

/// Bluefin pool creation's own tick-spacing bound.
macro public(package) fun bluefin_max_tick_spacing(): u32 {
    400
}

/// Bluefin pool creation's own fee-rate bound.
macro public(package) fun bluefin_max_fee_rate(): u64 {
    20_000
}

/// Aftermath's own bound on a DAO fee, the whole amount, which its DAO-fee pool creation asserts
/// as `fee_bps <= 10_000`.
macro public(package) fun aftermath_max_dao_fee_bps(): u16 {
    10_000
}

/// Each coin's Aftermath weight: half of Aftermath's `1e18` fixed-point one.
macro public(package) fun aftermath_half_weight(): u64 {
    500_000_000_000_000_000
}

/// Selects Aftermath's uncorrelated weighted-product curve.
macro public(package) fun aftermath_flatness(): u64 {
    0
}

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked LP.
macro public(package) fun aftermath_base_swap_fee(): u64 {
    100_000_000_000_000
}

/// Name of every Aftermath pool a presale creates.
macro public(package) fun aftermath_pool_name(): vector<u8> {
    b"Blast Presale Pool"
}
