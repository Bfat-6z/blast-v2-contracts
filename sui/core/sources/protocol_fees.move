// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the ledger's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fees held by one launch, presale, or vault, and their one payout path: to the treasury,
/// and, when the sale named a partner, the partner's cut of every asset first.
///
/// The embedding object owns the ledger, so only its module can accrue into it or pay it out; each
/// product wraps the payout in its own permissionless call.
module blast_core::protocol_fees;

// === Public Types ===

/// Blast's Meme, Quote, and SUI fees, held until paid. `partner_id` is fixed at creation: a ledger
/// bound to a partner pays only with that partner, so Blast's fees never skip the partner's cut.
public struct Ledger<phantom Meme, phantom Quote> has store {
    origin: ID,
    partner_id: Option<ID>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    sui: Balance<SUI>,
}

// === Public Functions ===

/// An empty ledger for the object `origin`, bound to `partner_id` if any.
public fun new<Meme, Quote>(origin: ID, partner_id: Option<ID>): Ledger<Meme, Quote> {
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_core::errors::invalid_pair!(),
    );

    Ledger {
        origin,
        partner_id,
        meme: balance::zero(),
        quote: balance::zero(),
        sui: balance::zero(),
    }
}

/// Adds Meme and Quote owned wholly by Blast.
public fun accrue<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
) {
    self.meme.join(meme);
    self.quote.join(quote);
}

/// Adds SUI owned wholly by Blast, such as a creation fee.
public fun accrue_sui<Meme, Quote>(self: &mut Ledger<Meme, Quote>, sui: Balance<SUI>) {
    self.sui.join(sui);
}

/// Takes Blast's share of one fee in each asset, rounded up, into the ledger and leaves the rest in
/// `meme_fee` and `quote_fee`. Returns the Meme and Quote taken.
public fun take_share<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    meme_fee: &mut Balance<Meme>,
    quote_fee: &mut Balance<Quote>,
    meme_share: Bps,
    quote_share: Bps,
): (u64, u64) {
    let meme_amount = meme_share.apply_up(meme_fee.value());
    let quote_amount = quote_share.apply_up(quote_fee.value());

    self.meme.join(meme_fee.split(meme_amount));
    self.quote.join(quote_fee.split(quote_amount));

    (meme_amount, quote_amount)
}

/// Pays everything held to the treasury. Aborts when the ledger is bound to a partner.
public fun pay<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    treasury: &Treasury,
    ctx: &mut TxContext,
) {
    assert!(self.partner_id.is_none(), blast_core::errors::partner_mismatch!());

    self.pay_treasury(treasury, 0, 0, 0, ctx);
}

/// Pays the bound partner its cut of each asset, then the treasury the rest. Aborts unless
/// `partner` is the ledger's partner.
public fun pay_with_partner<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    treasury: &Treasury,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    assert!(
        self.partner_id.contains(&object::id(partner)),
        blast_core::errors::partner_mismatch!(),
    );

    let partner_meme = partner.pay(&mut self.meme, ctx);
    let partner_quote = partner.pay(&mut self.quote, ctx);
    let partner_sui = partner.pay(&mut self.sui, ctx);

    self.pay_treasury(treasury, partner_meme, partner_quote, partner_sui, ctx);
}

public fun origin<Meme, Quote>(self: &Ledger<Meme, Quote>): ID { self.origin }

public fun partner_id<Meme, Quote>(self: &Ledger<Meme, Quote>): Option<ID> { self.partner_id }

/// The Meme, Quote, and SUI held.
public fun balances<Meme, Quote>(self: &Ledger<Meme, Quote>): (u64, u64, u64) {
    (self.meme.value(), self.quote.value(), self.sui.value())
}

// === Private Functions ===

fun pay_treasury<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    treasury: &Treasury,
    partner_meme: u64,
    partner_quote: u64,
    partner_sui: u64,
    ctx: &mut TxContext,
) {
    let destination = treasury.destination();
    let (meme, quote, sui) = self.balances();

    recipient::pay(&mut self.meme, meme, destination, ctx);
    recipient::pay(&mut self.quote, quote, destination, ctx);
    recipient::pay(&mut self.sui, sui, destination, ctx);

    event::emit(ProtocolFeesPaid<Meme, Quote> {
        origin: self.origin,
        treasury: destination,
        meme,
        quote,
        sui,
        partner_id: self.partner_id,
        partner_meme,
        partner_quote,
        partner_sui,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Ledger<Meme, Quote>) {
    let Ledger { meme, quote, sui, .. } = self;
    meme.destroy_for_testing();
    quote.destroy_for_testing();
    sui.destroy_for_testing();
}

#[test_only]
public fun paid_fields<Meme, Quote>(
    event: &ProtocolFeesPaid<Meme, Quote>,
): (ID, address, u64, u64, u64, Option<ID>, u64, u64, u64) {
    (
        event.origin,
        event.treasury,
        event.meme,
        event.quote,
        event.sui,
        event.partner_id,
        event.partner_meme,
        event.partner_quote,
        event.partner_sui,
    )
}

// === Events ===

/// Blast's held fees were paid: the treasury's amounts, and the partner's cut when one is bound.
public struct ProtocolFeesPaid<phantom Meme, phantom Quote> has copy, drop {
    origin: ID,
    treasury: address,
    meme: u64,
    quote: u64,
    sui: u64,
    partner_id: Option<ID>,
    partner_meme: u64,
    partner_quote: u64,
    partner_sui: u64,
}

// === Imports ===

use blast_core::{blast_treasury::Treasury, bps::Bps, recipient};

use blast_partners::blast_partners::Partner;

use std::type_name;

use sui::{balance::{Self, Balance}, event, sui::SUI};
