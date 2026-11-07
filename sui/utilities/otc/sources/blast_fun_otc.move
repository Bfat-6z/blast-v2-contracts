// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Fixed-price OTC offers: a maker escrows one coin and names the amount of another coin that
/// buys all of it.
module blast_fun_otc::blast_fun_otc;

// === Public Types ===

/// Key-only shared escrow for one offer whose rate and counterparty never change.
public struct Offer<phantom Offered, phantom Wanted> has key {
    id: UID,
    balance: Balance<Offered>,
    maker: address,
    taker: Option<address>,
    partial_fills: bool,
    offered_amount: u64,
    wanted_amount: u64,
}

// === Public Functions ===

/// Escrows `offered` for `wanted_amount` of a different coin type `Wanted`, payable to the sender
/// as maker. A `taker` restricts the offer to that one address; `partial_fills` lets takers buy
/// part of the escrow.
public fun new<Offered, Wanted>(
    offered: Coin<Offered>,
    wanted_amount: u64,
    taker: Option<address>,
    partial_fills: bool,
    ctx: &mut TxContext,
): Offer<Offered, Wanted> {
    assert!(taker.is_none_or!(|taker| *taker != @0x0), EInvalidTaker);
    let offered_amount = offered.value();
    assert!(offered_amount > 0, EZeroOffered);
    assert!(wanted_amount > 0, EZeroWanted);
    let offered_type = type_name::with_original_ids<Offered>();
    let wanted_type = type_name::with_original_ids<Wanted>();
    assert!(offered_type != wanted_type, ESameCoin);

    let offer = Offer {
        id: object::new(ctx),
        balance: offered.into_balance(),
        maker: ctx.sender(),
        taker,
        partial_fills,
        offered_amount,
        wanted_amount,
    };

    event::emit(OfferCreated {
        offer_id: offer.id.to_inner(),
        offered_type,
        wanted_type,
        taker,
        partial_fills,
        offered_amount,
        wanted_amount,
    });

    offer
}

/// Publishes a newly created offer as top-level shared state.
public fun share<Offered, Wanted>(self: Offer<Offered, Wanted>) {
    transfer::share_object(self);
}

/// Buys `amount` of the escrow at the offer's fixed rate and pays the maker from `payment`.
/// The cost is `amount * wanted_amount / offered_amount` rounded up for the maker, so a full
/// take costs exactly `wanted_amount` and a partial fill never pays below the rate.
public fun take<Offered, Wanted>(
    self: &mut Offer<Offered, Wanted>,
    amount: u64,
    payment: &mut Coin<Wanted>,
    ctx: &mut TxContext,
): Coin<Offered> {
    assert!(self.taker.is_none_or!(|taker| *taker == ctx.sender()), ENotTaker);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= self.balance.value(), EAmountExceedsBalance);
    assert!(self.partial_fills || amount == self.balance.value(), EPartialFillsDisabled);

    let paid = amount.mul_div_ceil(self.wanted_amount, self.offered_amount);

    transfer::public_transfer(payment.split(paid, ctx), self.maker);
    let bought = self.balance.split(amount).into_coin(ctx);

    event::emit(OfferTaken {
        offer_id: self.id.to_inner(),
        amount,
        paid,
    });

    bought
}

/// Deletes the offer and returns its remaining escrow, which may be zero, to the maker.
public fun cancel<Offered, Wanted>(
    self: Offer<Offered, Wanted>,
    ctx: &mut TxContext,
): Coin<Offered> {
    assert!(self.maker == ctx.sender(), ENotMaker);

    let Offer {
        id,
        balance,
        ..
    } = self;

    event::emit(OfferCanceled { offer_id: id.to_inner(), refund: balance.value() });

    id.delete();

    balance.into_coin(ctx)
}

// === Test-Only Functions ===

#[test_only]
public fun offer_created_fields(
    self: &OfferCreated,
): (ID, TypeName, TypeName, Option<address>, bool, u64, u64) {
    (
        self.offer_id,
        self.offered_type,
        self.wanted_type,
        self.taker,
        self.partial_fills,
        self.offered_amount,
        self.wanted_amount,
    )
}

#[test_only]
public fun offer_taken_fields(self: &OfferTaken): (ID, u64, u64) {
    (self.offer_id, self.amount, self.paid)
}

#[test_only]
public fun offer_canceled_fields(self: &OfferCanceled): (ID, u64) {
    (self.offer_id, self.refund)
}

// === Events ===

/// Emitted after a maker escrows a new offer.
public struct OfferCreated has copy, drop {
    offer_id: ID,
    offered_type: TypeName,
    wanted_type: TypeName,
    taker: Option<address>,
    partial_fills: bool,
    offered_amount: u64,
    wanted_amount: u64,
}

/// Emitted after the sender buys `amount` of the escrow and pays the maker `paid`.
public struct OfferTaken has copy, drop {
    offer_id: ID,
    amount: u64,
    paid: u64,
}

/// Emitted after the maker deletes an offer and recovers its remaining escrow.
public struct OfferCanceled has copy, drop {
    offer_id: ID,
    refund: u64,
}

// === Errors ===

#[error(code = 0)]
const EInvalidTaker: vector<u8> = b"Taker must not be the zero address.";

#[error(code = 1)]
const EZeroOffered: vector<u8> = b"Offered amount must be greater than zero.";

#[error(code = 2)]
const EZeroWanted: vector<u8> = b"Wanted amount must be greater than zero.";

#[error(code = 3)]
const ENotTaker: vector<u8> = b"Sender is not the taker this offer names.";

#[error(code = 4)]
const EZeroAmount: vector<u8> = b"Take amount must be greater than zero.";

#[error(code = 5)]
const EAmountExceedsBalance: vector<u8> = b"Take amount exceeds the offer balance.";

#[error(code = 6)]
const EPartialFillsDisabled: vector<u8> = b"Offer must be taken in full.";

#[error(code = 7)]
const ENotMaker: vector<u8> = b"Only the maker may cancel this offer.";

#[error(code = 8)]
const ESameCoin: vector<u8> = b"Offered and wanted coins must be different types.";

// === Imports ===

use std::type_name::{Self, TypeName};

use sui::{balance::Balance, coin::Coin, event};
