// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Presale event payloads and their package-only emitters. Pauses and versions emit from
/// `blast_admin`, delayed settings from its delayed modules, partner acceptance from
/// `blast_partners::partner_list`, and Blast's fee payments from `blast_core`. `PresaleCreated`
/// stays beside the sale terms it records in `blast_presale`, which would otherwise form a module
/// cycle.
module blast_presale::events;

// === Package Functions ===

public(package) fun quote_set<Quote>(allowed: bool) {
    sui::event::emit(QuoteSet<Quote> { allowed });
}

public(package) fun presale_opened<SaleToken, Quote>(
    presale_id: ID,
    start_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    uncapped_from_ms: u64,
    hard_cap_from_ms: Option<u64>,
    partner_id: Option<ID>,
) {
    sui::event::emit(PresaleOpened<SaleToken, Quote> {
        presale_id,
        start_ms,
        end_ms,
        liquidity_deadline_ms,
        uncapped_from_ms,
        hard_cap_from_ms,
        partner_id,
    });
}

public(package) fun protocol_fees_changed<SaleToken, Quote>(
    presale_id: ID,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    protocol_quote: u64,
    protocol_tokens: u64,
    token_allocation: u64,
) {
    sui::event::emit(ProtocolFeesChanged<SaleToken, Quote> {
        presale_id,
        protocol_raise_bps,
        protocol_token_bps,
        protocol_lp_fee_meme_bps,
        protocol_lp_fee_quote_bps,
        protocol_quote,
        protocol_tokens,
        token_allocation,
    });
}

public(package) fun committed<SaleToken, Quote>(
    presale_id: ID,
    quote: u64,
    wallet_commitment: u64,
    total_commitments: u64,
    participants: u64,
) {
    sui::event::emit(Committed<SaleToken, Quote> {
        presale_id,
        quote,
        wallet_commitment,
        total_commitments,
        participants,
    });
}

public(package) fun presale_funded<SaleToken, Quote>(
    presale_id: ID,
    total_commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
) {
    sui::event::emit(PresaleFunded<SaleToken, Quote> {
        presale_id,
        total_commitments,
        accepted_quote,
        refundable_quote,
        token_allocation,
        end_ms,
        liquidity_deadline_ms,
    });
}

public(package) fun presale_cancelled<SaleToken, Quote>(
    presale_id: ID,
    total_commitments: u64,
    refundable_quote: u64,
) {
    sui::event::emit(PresaleCancelled<SaleToken, Quote> {
        presale_id,
        total_commitments,
        refundable_quote,
    });
}

public(package) fun presale_migrated<SaleToken, Quote>(
    presale_id: ID,
    venue: TypeName,
    liquidity_quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
) {
    sui::event::emit(PresaleMigrated<SaleToken, Quote> {
        presale_id,
        venue,
        liquidity_quote,
        liquidity_tokens,
        recipient_tokens,
    });
}

public(package) fun raise_allocated<SaleToken, Quote>(
    presale_id: ID,
    recipient: address,
    quote: u64,
    vesting_id: Option<ID>,
) {
    sui::event::emit(RaiseAllocated<SaleToken, Quote> { presale_id, recipient, quote, vesting_id });
}

public(package) fun recipient_allocated<SaleToken, Quote>(
    presale_id: ID,
    recipient: address,
    tokens: u64,
    vesting_id: Option<ID>,
) {
    sui::event::emit(RecipientAllocated<SaleToken, Quote> {
        presale_id,
        recipient,
        tokens,
        vesting_id,
    });
}

public(package) fun claimed<SaleToken, Quote>(
    presale_id: ID,
    participant: address,
    wallet_commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_participants: u64,
    vesting_id: Option<ID>,
) {
    sui::event::emit(Claimed<SaleToken, Quote> {
        presale_id,
        participant,
        wallet_commitment,
        tokens,
        quote_refund,
        remaining_participants,
        vesting_id,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun quote_set_allowed<Quote>(event: &QuoteSet<Quote>): bool {
    event.allowed
}

#[test_only]
public fun opened_hard_cap_from_ms<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): Option<u64> {
    event.hard_cap_from_ms
}

#[test_only]
public fun opened_partner_id<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): Option<ID> {
    event.partner_id
}

#[test_only]
public fun opened_fields<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.start_ms,
        event.end_ms,
        event.liquidity_deadline_ms,
        event.uncapped_from_ms,
    )
}

#[test_only]
public fun protocol_fees_changed_fields<SaleToken, Quote>(
    event: &ProtocolFeesChanged<SaleToken, Quote>,
): (ID, vector<u64>, u64, u64, u64) {
    (
        event.presale_id,
        vector[
            event.protocol_raise_bps,
            event.protocol_token_bps,
            event.protocol_lp_fee_meme_bps,
            event.protocol_lp_fee_quote_bps,
        ],
        event.protocol_quote,
        event.protocol_tokens,
        event.token_allocation,
    )
}

#[test_only]
public fun committed_fields<SaleToken, Quote>(
    event: &Committed<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.quote,
        event.wallet_commitment,
        event.total_commitments,
        event.participants,
    )
}

#[test_only]
public fun funded_fields<SaleToken, Quote>(
    event: &PresaleFunded<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.total_commitments,
        event.accepted_quote,
        event.refundable_quote,
        event.token_allocation,
    )
}

#[test_only]
public fun funded_deadlines<SaleToken, Quote>(event: &PresaleFunded<SaleToken, Quote>): (u64, u64) {
    (event.end_ms, event.liquidity_deadline_ms)
}

#[test_only]
public fun cancelled_fields<SaleToken, Quote>(
    event: &PresaleCancelled<SaleToken, Quote>,
): (ID, u64, u64) {
    (event.presale_id, event.total_commitments, event.refundable_quote)
}

#[test_only]
public fun migrated_fields<SaleToken, Quote>(
    event: &PresaleMigrated<SaleToken, Quote>,
): (ID, TypeName, u64, u64, u64) {
    (
        event.presale_id,
        event.venue,
        event.liquidity_quote,
        event.liquidity_tokens,
        event.recipient_tokens,
    )
}

#[test_only]
public fun raise_allocated_fields<SaleToken, Quote>(
    event: &RaiseAllocated<SaleToken, Quote>,
): (ID, address, u64) {
    (event.presale_id, event.recipient, event.quote)
}

#[test_only]
public fun raise_allocated_vesting_id<SaleToken, Quote>(
    event: &RaiseAllocated<SaleToken, Quote>,
): Option<ID> {
    event.vesting_id
}

#[test_only]
public fun recipient_allocated_fields<SaleToken, Quote>(
    event: &RecipientAllocated<SaleToken, Quote>,
): (ID, address, u64) {
    (event.presale_id, event.recipient, event.tokens)
}

#[test_only]
public fun recipient_allocated_vesting_id<SaleToken, Quote>(
    event: &RecipientAllocated<SaleToken, Quote>,
): Option<ID> {
    event.vesting_id
}

#[test_only]
public fun claim_fields<SaleToken, Quote>(
    event: &Claimed<SaleToken, Quote>,
): (ID, address, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.participant,
        event.wallet_commitment,
        event.tokens,
        event.quote_refund,
        event.remaining_participants,
    )
}

#[test_only]
public fun claimed_vesting_id<SaleToken, Quote>(event: &Claimed<SaleToken, Quote>): Option<ID> {
    event.vesting_id
}

// === Events ===

/// Presales created afterward may (`allowed`) or may not raise `Quote`.
public struct QuoteSet<phantom Quote> has copy, drop {
    allowed: bool,
}

/// A presale was shared with these commitment and liquidity windows and its Blast partner, if
/// any. Commitments open at `start_ms`, which may be later than the share. A sale whose hard cap
/// closes it when filled may end earlier; `PresaleFunded` records when it did.
public struct PresaleOpened<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    start_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    uncapped_from_ms: u64,
    hard_cap_from_ms: Option<u64>,
    partner_id: Option<ID>,
}

/// Before the window started, Blast's `FeeAdmin` replaced this sale's Blast rates, moving Blast's
/// tokens to or from the sale allocation and its Quote to or from the LP's.
public struct ProtocolFeesChanged<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    /// Blast's shares of the raise and of the supply, paid on migration.
    protocol_quote: u64,
    protocol_tokens: u64,
    /// The tokens buyers now share pro rata.
    token_allocation: u64,
}

/// Quote joined a presale from the transaction sender.
public struct Committed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    quote: u64,
    wallet_commitment: u64,
    total_commitments: u64,
    participants: u64,
}

/// A funded presale closed at `end_ms` with these fixed claim totals; anyone may cancel it once
/// it is still unmigrated at `liquidity_deadline_ms`. Both are earlier than `PresaleOpened`'s
/// when the sale closed early.
public struct PresaleFunded<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    total_commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
}

/// A presale became fully refundable without releasing Quote.
public struct PresaleCancelled<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    total_commitments: u64,
    refundable_quote: u64,
}

/// The raise left after Blast's and the recipients' shares, and the LP-token allocation, left
/// the sale in its hand-off to `venue`.
public struct PresaleMigrated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    venue: TypeName,
    liquidity_quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
}

/// One configured recipient received its share of the raise, or the vesting schedule
/// `vesting_id` that holds it.
public struct RaiseAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    quote: u64,
    vesting_id: Option<ID>,
}

/// One configured recipient received its immutable token allocation, or the vesting schedule
/// `vesting_id` that holds it.
public struct RecipientAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    tokens: u64,
    vesting_id: Option<ID>,
}

/// `participant` received its token allocation, or the vesting schedule `vesting_id` that holds
/// it, and its Quote refund, leaving `remaining_participants` wallets still to claim.
public struct Claimed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    participant: address,
    wallet_commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_participants: u64,
    vesting_id: Option<ID>,
}

// === Imports ===

use std::type_name::TypeName;
