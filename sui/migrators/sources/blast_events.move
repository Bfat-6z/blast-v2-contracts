// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Typed replay facts for vault custody, LP-fee collection, auto-LP, holder rewards, Cetus pool
/// reservations, and residual claims. Delayed settings, upgrade custody and the creator split
/// record their lifecycle through `blast_admin::delayed` events.
module blast_fun_migrators::blast_events;

// === Public Types ===

/// Records discovery and typed position custody for one completed vault: the position's
/// `liquidity`, the handoff the venue returned as protocol residuals, and the creator's fee split
/// it holds from migration.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    launch_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
}

/// One nonzero collection split under the vault's split: Blast's share, the creator, auto-LP,
/// rewards, and burn shares, and every recipient's amount in the split's recipient order.
/// `burn_meme` was burned; `burn_quote` waits for a buyback.
public struct FeesCollected has copy, drop {
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    /// Where Blast's share was paid, or none when a partnered vault holds it for the partner claim.
    protocol_destination: Option<address>,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
}

/// Auto-LP added these amounts to the position; the rest waits in the vault.
public struct AutoLiquidityAdded has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
}

/// A buyback admin swapped `quote_spent` of the burn Quote for `meme_burned` Meme and burned it;
/// `burn_quote_pending` still waits.
public struct BuybackBurned has copy, drop {
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
}

/// The vault opened the separate position auto-LP adds to.
public struct AutoLpPositionOpened has copy, drop {
    vault_id: ID,
    position_id: ID,
}

/// The live curve-fee cap holder claimed the creator's accrued LP fees.
public struct CreatorFeesClaimed has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

/// A holder-reward allocation commitment, its reserved funds, and the vault's unreserved rewards.
public struct RoundPublished has copy, drop {
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

/// One-shot gas reimbursement and the unused Quote restored to its vault.
public struct GasReserveSettled has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

/// Deadline recovery of unclaimed holder assets and any unsettled reserve.
public struct RoundClosed has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

/// A completed holder-reward payout and both remaining round balances.
public struct RewardPaid has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

/// Records a protocol migration-residual claim.
public struct ProtocolFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

/// A partnered vault paid the Blast LP fees it held: `partner_meme` and `partner_quote` to the
/// launch's partner, and the rest, `blast_meme` and `blast_quote`, to `protocol_destination`.
public struct ProtocolLpFeesClaimed has copy, drop {
    vault_id: ID,
    protocol_destination: address,
    blast_meme: u64,
    blast_quote: u64,
    partner_meme: u64,
    partner_quote: u64,
}

/// Records Cetus pool creation reserved for one pair at the tick spacing its migration uses.
public struct CetusPoolReserved has copy, drop {
    meme: TypeName,
    quote: TypeName,
    pool_creation_cap_id: ID,
    tick_spacing: u32,
}

// === Package Functions ===

/// Emits creation of one venue-sealed LP vault, its attached position, and its fee split.
public(package) fun vault_created<Meme, Quote, Venue>(
    vault_id: ID,
    launch_id: ID,
    pool_id: ID,
    position_id: ID,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
) {
    sui::event::emit(VaultCreated {
        vault_id,
        launch_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        residual_meme,
        residual_quote,
        liquidity,
        fee_split,
    });
}

/// Emits one nonzero collection split.
public(package) fun fees_collected(
    vault_id: ID,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: Option<address>,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
) {
    sui::event::emit(FeesCollected {
        vault_id,
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        creator_meme,
        creator_quote,
        auto_lp_meme,
        auto_lp_quote,
        rewards_meme,
        rewards_quote,
        burn_meme,
        burn_quote,
        recipient_meme,
        recipient_quote,
    });
}

/// Emits one buyback and burn.
public(package) fun buyback_burned(
    vault_id: ID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
) {
    sui::event::emit(BuybackBurned { vault_id, quote_spent, meme_burned, burn_quote_pending });
}

/// Emits one nonzero auto-LP addition and the amounts still waiting.
public(package) fun auto_liquidity_added(
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
) {
    sui::event::emit(AutoLiquidityAdded {
        vault_id,
        meme_amount,
        quote_amount,
        auto_lp_meme_pending,
        auto_lp_quote_pending,
    });
}

/// Emits the opening of a vault's auto-LP position.
public(package) fun auto_lp_position_opened(vault_id: ID, position_id: ID) {
    sui::event::emit(AutoLpPositionOpened { vault_id, position_id });
}

/// Emits a creator LP-fee claim.
public(package) fun creator_fees_claimed(vault_id: ID, meme_amount: u64, quote_amount: u64) {
    sui::event::emit(CreatorFeesClaimed { vault_id, meme_amount, quote_amount });
}

/// Emits a published holder-reward round.
public(package) fun round_published(
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
    sui::event::emit(RoundPublished {
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

/// Emits gas reserve settled.
public(package) fun gas_reserve_settled(
    vault_id: ID,
    round_id: ID,
    number: u64,
    treasury: address,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
) {
    sui::event::emit(GasReserveSettled {
        vault_id,
        round_id,
        number,
        treasury,
        reimbursement_amount,
        reserve_returned,
        quote_unallocated,
    });
}

/// Emits round closed.
public(package) fun round_closed(
    vault_id: ID,
    round_id: ID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
) {
    sui::event::emit(RoundClosed {
        vault_id,
        round_id,
        number,
        meme_returned,
        quote_returned,
        gas_reserve_returned,
    });
}

/// Emits one holder-reward payout.
public(package) fun reward_paid(
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
) {
    sui::event::emit(RewardPaid {
        round_id,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining,
        quote_remaining,
    });
}

/// Emits a protocol-owned migration-residual withdrawal.
public(package) fun protocol_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(ProtocolFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits a partnered vault's claim of the Blast LP fees it held.
public(package) fun protocol_lp_fees_claimed(
    vault_id: ID,
    protocol_destination: address,
    blast_meme: u64,
    blast_quote: u64,
    partner_meme: u64,
    partner_quote: u64,
) {
    sui::event::emit(ProtocolLpFeesClaimed {
        vault_id,
        protocol_destination,
        blast_meme,
        blast_quote,
        partner_meme,
        partner_quote,
    });
}

/// Emits the Cetus pair reservation made while starting a launch.
public(package) fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32) {
    sui::event::emit(CetusPoolReserved {
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        pool_creation_cap_id,
        tick_spacing,
    });
}

// === Imports ===

use blast_fun::allocation::FeeSplit;

use std::type_name::{Self, TypeName};
