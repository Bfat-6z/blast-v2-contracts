// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Event payloads and their package-only emitters for `blast_core`.
module blast_core::blast_core_events;

// === Package Functions ===

public(package) fun protocol_fees_paid<Meme, Quote>(
    package_witness: TypeName,
    origin: ID,
    treasury: address,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_id: Option<ID>,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
) {
    sui::event::emit(ProtocolFeesPaid<Meme, Quote> {
        package_witness,
        origin,
        treasury,
        meme_amount,
        quote_amount,
        sui_amount,
        partner_id,
        partner_meme_amount,
        partner_quote_amount,
        partner_sui_amount,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun protocol_fees_paid_fields<Meme, Quote>(
    event: &ProtocolFeesPaid<Meme, Quote>,
): (TypeName, ID, address, u64, u64, u64, Option<ID>, u64, u64, u64) {
    (
        event.package_witness,
        event.origin,
        event.treasury,
        event.meme_amount,
        event.quote_amount,
        event.sui_amount,
        event.partner_id,
        event.partner_meme_amount,
        event.partner_quote_amount,
        event.partner_sui_amount,
    )
}

// === Events ===

/// Blast's held fees were paid from the ledger of `origin`, created under `package_witness`: the
/// treasury's amounts, and the partner's cut when a partner is bound.
public struct ProtocolFeesPaid<phantom Meme, phantom Quote> has copy, drop {
    package_witness: TypeName,
    origin: ID,
    treasury: address,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_id: Option<ID>,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
}

// === Imports ===

use std::type_name::TypeName;
