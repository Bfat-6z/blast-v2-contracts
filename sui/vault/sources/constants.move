// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide vault constants exposed as zero-cost macros.
module blast_vault::constants;

// === Package Constants ===

/// The package generation this bytecode serves.
macro public(package) fun generation(): u64 {
    1
}

/// Stops Blast's administrative operations: protocol-share changes, holder-reward rounds, gas
/// settlement, and buyback. Venue admission, collection, owner actions, claims, closes, and cancels
/// never pause.
macro public(package) fun admin_pause_bit(): u8 {
    1
}

/// Every supported vault pause flag.
macro public(package) fun valid_pause_bits(): u8 {
    blast_vault::constants::admin_pause_bit!()
}

/// Initial venue admission notice: zero, so Blast lists its venues at launch while publication
/// keeps the package paused. `blast_vault_package::unpause` refuses until a nonzero notice applies.
macro public(package) fun venue_admission_delay_ms(): u64 {
    0
}

/// Initial notice before a vault's fee split or Blast share changes.
macro public(package) fun fee_change_delay_ms(): u64 {
    48 * 60 * 60 * 1_000
}

/// Initial notice before a scheduled holder-reward round may publish, or its next notice period
/// may change: 2 hours, so a cancel administrator can stop a bad round while daily rounds fit.
macro public(package) fun round_notice_ms(): u64 {
    2 * 60 * 60 * 1_000
}

/// Blast's largest share of each LP-fee collection, per asset.
macro public(package) fun max_protocol_bps(): u64 {
    3_000
}

/// Largest holder-reward gas reserve, in basis points of the round's holder Quote.
macro public(package) fun max_gas_reserve_bps(): u64 {
    1_000
}

/// Denominator for rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// The most leaves one holder-reward round may commit.
macro public(package) fun max_reward_leaves(): u64 {
    65_536
}

/// Byte length of a round's Merkle root and manifest digest.
macro public(package) fun digest_length(): u64 {
    32
}

/// The domain every holder-reward leaf hashes under.
macro public(package) fun reward_leaf_domain(): vector<u8> {
    b"blast-holder-rewards-v2"
}
