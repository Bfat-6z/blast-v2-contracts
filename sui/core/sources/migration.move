// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the hand-off's abort location.
#[allow(lint(abort_without_constant))]
/// The sealed contract between a sale and the venue that migrates it.
///
/// Before supply leaves the sale's `TreasuryCap`, a venue prepares the coin and returns a
/// `VenueBinding` sealed by its witness; the product admits and stores the binding's venue. At
/// migration the product opens a `Migration` sealed by its own witness, carrying the pool's
/// balances and the new vault's terms, and only the stored venue's witness can redeem it. Neither
/// value can be dropped, copied, or stored, so a transaction completes the migration whole or
/// aborts.
module blast_core::migration;

// === Public Types ===

/// The pool tier a venue reserved for the coin: Cetus and Bluefin take a tick spacing and fee
/// rate; Aftermath takes no tick spacing and its DAO fee as the rate.
public struct PoolTier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// What happens to the migration residuals the pool does not take.
public enum ResidualPolicy has copy, drop, store {
    /// Paid to Blast through the vault's protocol ledger.
    Protocol,
    /// Held in the vault for the sale's owner to claim.
    Owner,
}

/// Everything a new vault snapshots from the sale that opened it.
public struct VaultTerms has copy, drop, store {
    /// The launch or presale the vault belongs to; owner proofs name it.
    origin: ID,
    /// The original type of the product witness that opened the hand-off.
    product: TypeName,
    fee_split: FeeSplit,
    /// Blast's share of each LP-fee collection, per asset.
    protocol_meme_bps: Bps,
    protocol_quote_bps: Bps,
    partner_id: Option<ID>,
    residuals: ResidualPolicy,
}

/// A venue's sealed preparation of one coin, consumed by the product that admits it.
public struct VenueBinding {
    venue: TypeName,
    tier: PoolTier,
}

/// One sale's pool balances and vault terms, redeemable only by `venue`.
public struct Migration<phantom Meme, phantom Quote> {
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    venue: TypeName,
    terms: VaultTerms,
}

// === Public Functions ===

public fun pool_tier(tick_spacing: u32, fee_rate: u64): PoolTier {
    PoolTier { tick_spacing, fee_rate }
}

public fun protocol_residuals(): ResidualPolicy { ResidualPolicy::Protocol }

public fun owner_residuals(): ResidualPolicy { ResidualPolicy::Owner }

/// Seals a venue's preparation under its witness `Venue`.
public fun bind<Venue: drop>(_: Venue, tier: PoolTier): VenueBinding {
    VenueBinding { venue: type_name::with_original_ids<Venue>(), tier }
}

/// Consumes a binding, returning the venue witness type to admit and store and its tier.
public fun unbind(self: VenueBinding): (TypeName, PoolTier) {
    let VenueBinding { venue, tier } = self;

    (venue, tier)
}

/// Opens a sale's migration under its product witness `Product`, for the stored `venue`. Each
/// Blast share is at most 10,000; the product enforces its own policy maximum.
public fun open<Meme, Quote, Product: drop>(
    _: Product,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    venue: TypeName,
    origin: ID,
    fee_split: FeeSplit,
    protocol_meme_bps: Bps,
    protocol_quote_bps: Bps,
    partner_id: Option<ID>,
    residuals: ResidualPolicy,
): Migration<Meme, Quote> {
    let terms = VaultTerms {
        origin,
        product: type_name::with_original_ids<Product>(),
        fee_split,
        protocol_meme_bps,
        protocol_quote_bps,
        partner_id,
        residuals,
    };

    Migration { meme, quote, venue, terms }
}

/// Redeems the migration under the stored venue's witness `Venue`, returning the pool's balances
/// and the vault's terms. Aborts for any other venue.
public fun redeem<Meme, Quote, Venue: drop>(
    self: Migration<Meme, Quote>,
    _: Venue,
): (Balance<Meme>, Balance<Quote>, VaultTerms) {
    let Migration { meme, quote, venue, terms } = self;
    assert!(venue == type_name::with_original_ids<Venue>(), blast_core::errors::wrong_venue!());

    (meme, quote, terms)
}

public fun venue<Meme, Quote>(self: &Migration<Meme, Quote>): TypeName { self.venue }

/// The pool's Meme and Quote amounts.
public fun amounts<Meme, Quote>(self: &Migration<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

public fun tick_spacing(self: &PoolTier): u32 { self.tick_spacing }

public fun fee_rate(self: &PoolTier): u64 { self.fee_rate }

public fun origin(self: &VaultTerms): ID { self.origin }

public fun product(self: &VaultTerms): TypeName { self.product }

public fun fee_split(self: &VaultTerms): FeeSplit { self.fee_split }

/// Blast's share of each LP-fee collection, Meme then Quote.
public fun protocol_shares(self: &VaultTerms): (Bps, Bps) {
    (self.protocol_meme_bps, self.protocol_quote_bps)
}

public fun partner_id(self: &VaultTerms): Option<ID> { self.partner_id }

public fun pays_residuals_to_protocol(self: &VaultTerms): bool {
    self.residuals == ResidualPolicy::Protocol
}

// === Imports ===

use blast_core::{bps::Bps, fee_split::FeeSplit};

use std::type_name::{Self, TypeName};

use sui::balance::Balance;
