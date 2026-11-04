// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Event payloads and their package-only emitters for `blast_vault`. Delayed settings, venue
/// admission, pauses, and versions emit from `blast_admin`; Blast's fee payments emit from
/// `blast_core`.
module blast_vault::blast_vault_events;

// === Package Functions ===

public(package) fun vault_created<Meme, Quote, Venue>(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    terms: VaultTerms,
    residual_meme_amount: u64,
    residual_quote_amount: u64,
) {
    sui::event::emit(VaultCreated<Meme, Quote, Venue> {
        vault_id,
        pool_id,
        position_id,
        liquidity,
        terms,
        residual_meme_amount,
        residual_quote_amount,
    });
}

public(package) fun fees_collected<Meme, Quote>(
    vault_id: ID,
    gross_meme_amount: u64,
    gross_quote_amount: u64,
    protocol_meme_amount: u64,
    protocol_quote_amount: u64,
    route_meme_amounts: vector<u64>,
    route_quote_amounts: vector<u64>,
) {
    sui::event::emit(FeesCollected<Meme, Quote> {
        vault_id,
        gross_meme_amount,
        gross_quote_amount,
        protocol_meme_amount,
        protocol_quote_amount,
        route_meme_amounts,
        route_quote_amounts,
    });
}

public(package) fun auto_lp_position_opened<Meme, Quote>(vault_id: ID, position_id: ID) {
    sui::event::emit(AutoLpPositionOpened<Meme, Quote> { vault_id, position_id });
}

public(package) fun auto_liquidity_added<Meme, Quote>(
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
) {
    sui::event::emit(AutoLiquidityAdded<Meme, Quote> {
        vault_id,
        meme_amount,
        quote_amount,
        auto_lp_meme_pending,
        auto_lp_quote_pending,
    });
}

public(package) fun buyback_burned<Meme, Quote>(
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
) {
    sui::event::emit(BuybackBurned<Meme, Quote> {
        vault_id,
        quote_spent,
        meme_burned,
        burn_quote_pending,
    });
}

public(package) fun owner_balances_claimed<Meme, Quote>(
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(OwnerBalancesClaimed<Meme, Quote> { vault_id, meme_amount, quote_amount });
}

public(package) fun round_published<Meme, Quote>(
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
    treasury: address,
    gas_reserve_amount: u64,
) {
    sui::event::emit(RoundPublished<Meme, Quote> {
        vault_id,
        round_id,
        number,
        start_checkpoint,
        end_checkpoint,
        claim_deadline_at_ms,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated,
        quote_unallocated,
        treasury,
        gas_reserve_amount,
    });
}

public(package) fun reward_claimed<Meme, Quote>(
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
) {
    sui::event::emit(RewardClaimed<Meme, Quote> {
        round_id,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining,
        quote_remaining,
    });
}

public(package) fun gas_reserve_settled<Meme, Quote>(
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
) {
    sui::event::emit(GasReserveSettled<Meme, Quote> {
        vault_id,
        round_id,
        number,
        treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    });
}

public(package) fun round_closed<Meme, Quote>(
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
) {
    sui::event::emit(RoundClosed<Meme, Quote> {
        vault_id,
        round_id,
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
    });
}

// === Test-Only Functions ===

#[test_only]
/// The `AutoLiquidityAdded` payload with these fields, for comparing emitted events.
public fun auto_liquidity_added_for_testing<Meme, Quote>(
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
): AutoLiquidityAdded<Meme, Quote> {
    AutoLiquidityAdded {
        vault_id,
        meme_amount,
        quote_amount,
        auto_lp_meme_pending,
        auto_lp_quote_pending,
    }
}

#[test_only]
/// The `BuybackBurned` payload with these fields, for comparing emitted events.
public fun buyback_burned_for_testing<Meme, Quote>(
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
): BuybackBurned<Meme, Quote> {
    BuybackBurned { vault_id, quote_spent, meme_burned, burn_quote_pending }
}

// === Events ===

/// A venue created and shared a vault with its position and settled its migration residuals.
public struct VaultCreated<phantom Meme, phantom Quote, phantom Venue> has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    liquidity: u128,
    terms: VaultTerms,
    residual_meme_amount: u64,
    residual_quote_amount: u64,
}

/// One collection was split: Blast's cut, then each route's part in the applied split's order.
public struct FeesCollected<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    gross_meme_amount: u64,
    gross_quote_amount: u64,
    protocol_meme_amount: u64,
    protocol_quote_amount: u64,
    route_meme_amounts: vector<u64>,
    route_quote_amounts: vector<u64>,
}

/// The venue attached the vault's auto-LP position.
public struct AutoLpPositionOpened<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    position_id: ID,
}

/// Auto-LP added liquidity, with what still waits for the next call.
public struct AutoLiquidityAdded<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
}

/// Burn Quote bought Meme that was burned, with the burn Quote still waiting.
public struct BuybackBurned<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
}

/// The owner claimed its accrued fees and residuals.
public struct OwnerBalancesClaimed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// A holder-reward round was published with its terms and the vault's remaining rewards.
public struct RoundPublished<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    claim_deadline_at_ms: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
    treasury: address,
    gas_reserve_amount: u64,
}

/// A leaf was paid, with the round's remaining balances.
public struct RewardClaimed<phantom Meme, phantom Quote> has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

/// A round's gas reserve was settled, with the vault's unreserved Quote after the return.
public struct GasReserveSettled<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

/// A round closed and returned its remainder to its vault.
public struct RoundClosed<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

// === Imports ===

use blast_core::migration::VaultTerms;
