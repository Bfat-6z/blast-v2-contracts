// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide presale constants exposed as zero-cost macros. The basis-points denominator and
/// Blast's LP-fee share maximum come from `blast_core::constants`.
module blast_presale::constants;

// === Package Constants ===

/// The package generation this bytecode serves.
macro public(package) fun generation(): u64 {
    1
}

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

/// Technical bound on the dynamic commitment records one presale may hold.
macro public(package) fun max_participants(): u64 {
    65_536
}

/// Bounds the token and raise recipient lists, both paid in the one migration transaction.
macro public(package) fun max_recipients(): u64 {
    64
}

/// The shortest LP-migration window. Migration is permissionless, so a funded sale reaches its
/// refund exit only after a week in which nobody migrated it, and a sale that nobody settled by
/// its end cannot be settled and cancelled in one transaction inside that week.
macro public(package) fun min_liquidity_window_duration_ms(): u64 {
    7 * 24 * 60 * 60 * 1_000
}

/// Blast's largest share of a sale's raise.
macro public(package) fun max_raise_bps(): u64 {
    1_000
}

/// Blast's largest share of a sale's tokens.
macro public(package) fun max_token_bps(): u64 {
    1_000
}

/// Byte length of a Blake2b-256 digest: an allowlist's Merkle root.
macro public(package) fun digest_length(): u64 {
    32
}

/// The Merkle leaf domain of every presale allowlist, `blast_core::merkle::leaf`'s domain for
/// each `(index, wallet, wallet_cap)` payload.
macro public(package) fun allowlist_leaf_domain(): vector<u8> {
    b"blast-presale-v1"
}
