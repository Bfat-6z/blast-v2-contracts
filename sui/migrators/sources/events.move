// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Event payloads and their package-only emitters for `blast_migrators`: the pool tier each venue
/// records while preparing a pair. Vault creation, LP-fee collection, auto-LP, buybacks, and holder
/// rewards emit from `blast_vault`; versions and upgrades from `blast_admin`.
module blast_migrators::events;

// === Public Types ===

/// Cetus pool creation for the pair is reserved under `pool_creation_cap_id`, the Meme type's one
/// `PoolCreationCap`, at the tick spacing its migration uses.
public struct CetusPoolReserved<phantom Meme, phantom Quote> has copy, drop {
    pool_creation_cap_id: ID,
    tick_spacing: u32,
}

/// The Bluefin pool tier the pair's migration uses.
public struct BluefinPoolTierRecorded<phantom Meme, phantom Quote> has copy, drop {
    tick_spacing: u32,
    fee_rate: u64,
}

// === Package Functions ===

public(package) fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32) {
    sui::event::emit(CetusPoolReserved<Meme, Quote> { pool_creation_cap_id, tick_spacing });
}

public(package) fun bluefin_pool_tier_recorded<Meme, Quote>(tick_spacing: u32, fee_rate: u64) {
    sui::event::emit(BluefinPoolTierRecorded<Meme, Quote> { tick_spacing, fee_rate });
}

// === Test-Only Functions ===

#[test_only]
/// The `CetusPoolReserved` payload with these fields, for comparing emitted events.
public fun cetus_pool_reserved_for_testing<Meme, Quote>(
    pool_creation_cap_id: ID,
    tick_spacing: u32,
): CetusPoolReserved<Meme, Quote> {
    CetusPoolReserved { pool_creation_cap_id, tick_spacing }
}

#[test_only]
/// The `BluefinPoolTierRecorded` payload with these fields, for comparing emitted events.
public fun bluefin_pool_tier_recorded_for_testing<Meme, Quote>(
    tick_spacing: u32,
    fee_rate: u64,
): BluefinPoolTierRecorded<Meme, Quote> {
    BluefinPoolTierRecorded { tick_spacing, fee_rate }
}
