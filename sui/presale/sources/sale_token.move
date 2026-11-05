// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// One-time-witness creation of a sale token whose `TreasuryCap` is sealed under the presale's
/// witness from birth, so no one mints before the sale's `finalize` mints the whole supply.
///
/// A generated sale-token package's initializer calls `new` with its witness and delivers the
/// sealed cap to the publisher, beside whatever it does with the currency's `MetadataCap`. The
/// publisher hands the sealed cap to an admitted venue's `prepare`, which borrows it to reserve
/// the pair's pool creation, and then to `blast_presale::new`, the only call that opens it.
module blast_presale::sale_token;

// === Public Functions ===

/// Registers the currency with the generated package's one-time witness and seals its
/// `TreasuryCap` under the presale's witness, returning the registry initializer for the
/// package to finalize beside it. Only that package's initializer holds the witness.
public fun new<SaleToken: drop>(
    otw: SaleToken,
    decimals: u8,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): (CurrencyInitializer<SaleToken>, SealedTreasuryCap<SaleToken>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        decimals,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );

    (initializer, sealed_treasury_cap::new(package_witness(), treasury_cap, ctx))
}

// === Imports ===

use blast_core::sealed_treasury_cap::{Self, SealedTreasuryCap};

use blast_presale::blast_presale_package::package_witness;

use std::string::String;

use sui::coin_registry::{Self, CurrencyInitializer};
