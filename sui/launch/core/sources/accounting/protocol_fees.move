// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the ledger's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fees held by one launch, presale, or vault, and their one payout path: to the treasury,
/// and, when the sale named a partner, the partner's cut of every asset first.
///
/// Only the module that defines the `PackageWitness` can create a ledger, and the payout event
/// names that witness's original type, so a fee payment's origin is attributable to the product or
/// vault that holds it. The embedding object owns the ledger, so only its module can accrue into
/// it or pay it out; each product wraps the payout in its own permissionless call.
module blast_core::protocol_fees;

// === Public Types ===

/// Blast's Meme, Quote, and SUI fees, held until paid. `partner_id` is fixed at creation: a ledger
/// bound to a partner pays only with that partner, so Blast's fees never skip the partner's cut.
public struct Ledger<phantom Meme, phantom Quote> has store {
    /// The original type of the package witness that created the ledger.
    package_witness: TypeName,
    origin: ID,
    partner_id: Option<ID>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    sui: Balance<SUI>,
}

// === Public Functions ===

/// An empty ledger for the object whose UID is borrowed as `origin`, created under the embedding
/// module's `PackageWitness` and bound to `partner_id` if any.
public fun new<Meme, Quote, PackageWitness: drop>(
    _: PackageWitness,
    origin: &UID,
    partner_id: Option<ID>,
): Ledger<Meme, Quote> {
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_core::errors::invalid_pair!(),
    );

    Ledger {
        package_witness: type_name::with_original_ids<PackageWitness>(),
        origin: origin.to_inner(),
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

/// Takes Blast's cut of one fee in each asset, `meme_bps` and `quote_bps` rounded up, into the
/// ledger and leaves the rest in `meme_fee` and `quote_fee`. Returns the Meme and Quote taken.
public fun take_cut<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    meme_fee: &mut Balance<Meme>,
    quote_fee: &mut Balance<Quote>,
    meme_bps: Bps,
    quote_bps: Bps,
): (u64, u64) {
    let meme_amount = meme_bps.apply_up(meme_fee.value());
    let quote_amount = quote_bps.apply_up(quote_fee.value());

    self.meme.join(meme_fee.split(meme_amount));
    self.quote.join(quote_fee.split(quote_amount));

    (meme_amount, quote_amount)
}

/// Pays everything held to the treasury; an empty ledger sends and emits nothing. Aborts when the
/// ledger is bound to a partner.
public fun pay<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    treasury: &Treasury,
    ctx: &mut TxContext,
) {
    assert!(self.partner_id.is_none(), blast_core::errors::partner_mismatch!());

    self.pay_treasury(treasury, 0, 0, 0, ctx);
}

/// Pays the bound partner its cut of each asset, then the treasury the rest; an empty ledger sends
/// and emits nothing. Aborts unless `partner` is the ledger's partner.
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

    let partner_meme_amount = partner.pay(&mut self.meme, ctx);
    let partner_quote_amount = partner.pay(&mut self.quote, ctx);
    let partner_sui_amount = partner.pay(&mut self.sui, ctx);

    self.pay_treasury(treasury, partner_meme_amount, partner_quote_amount, partner_sui_amount, ctx);
}

/// Deletes a ledger that holds nothing; pay it out first. Aborts while any fee is held, so no
/// destruction loses Blast's or the partner's fees.
public fun destroy<Meme, Quote>(self: Ledger<Meme, Quote>) {
    let (meme_amount, quote_amount, sui_amount) = self.balances();
    assert!(
        meme_amount == 0 && quote_amount == 0 && sui_amount == 0,
        blast_core::errors::ledger_not_empty!(),
    );

    let Ledger { meme, quote, sui, .. } = self;

    meme.destroy_zero();
    quote.destroy_zero();
    sui.destroy_zero();
}

/// The Meme, Quote, and SUI held.
public fun balances<Meme, Quote>(self: &Ledger<Meme, Quote>): (u64, u64, u64) {
    (self.meme.value(), self.quote.value(), self.sui.value())
}

/// The original type of the package witness that created the ledger.
public fun package_witness<Meme, Quote>(self: &Ledger<Meme, Quote>): TypeName {
    self.package_witness
}

/// The launch, presale, or vault whose fees the ledger holds.
public fun origin<Meme, Quote>(self: &Ledger<Meme, Quote>): ID { self.origin }

/// The partner the ledger pays with, fixed at creation, if any.
public fun partner_id<Meme, Quote>(self: &Ledger<Meme, Quote>): Option<ID> { self.partner_id }

// === Private Functions ===

/// Pays everything held to the treasury after the partner's cut was paid; sends and emits nothing
/// when neither was paid anything.
fun pay_treasury<Meme, Quote>(
    self: &mut Ledger<Meme, Quote>,
    treasury: &Treasury,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
    ctx: &mut TxContext,
) {
    let destination = treasury.destination();
    let (meme_amount, quote_amount, sui_amount) = self.balances();
    if (
        meme_amount + partner_meme_amount == 0
            && quote_amount + partner_quote_amount == 0
            && sui_amount + partner_sui_amount == 0
    ) return;

    payout::pay(&mut self.meme, meme_amount, destination, ctx);
    payout::pay(&mut self.quote, quote_amount, destination, ctx);
    payout::pay(&mut self.sui, sui_amount, destination, ctx);

    blast_core_events::protocol_fees_paid<Meme, Quote>(
        self.package_witness,
        self.origin,
        destination,
        meme_amount,
        quote_amount,
        sui_amount,
        self.partner_id,
        partner_meme_amount,
        partner_quote_amount,
        partner_sui_amount,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing<Meme, Quote>(self: Ledger<Meme, Quote>) {
    let Ledger { meme, quote, sui, .. } = self;
    meme.destroy_for_testing();
    quote.destroy_for_testing();
    sui.destroy_for_testing();
}

// === Imports ===

use blast_core::{blast_core_events, blast_treasury::Treasury, bps::Bps, payout};

use blast_partners::blast_partners::Partner;

use std::type_name::{Self, TypeName};

use sui::{balance::{Self, Balance}, sui::SUI};
