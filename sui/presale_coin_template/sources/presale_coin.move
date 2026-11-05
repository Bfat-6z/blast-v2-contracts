// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Generated sale-token package whose one-time witness creates its currency at publication with
/// the `TreasuryCap` sealed under the Blast presale.
module presale_coin_template::presale_coin;

// === Constants ===

const SYMBOL: vector<u8> = b"SALE";

const NAME: vector<u8> = b"Blast Sale Token";

const DESCRIPTION: vector<u8> = b"A token sold on Blast";

const ICON_URL: vector<u8> = b"https://blast.fun/sale.png";

const DECIMALS: u8 = 9;

/// True delivers the `MetadataCap` to `METADATA_CAP_RECIPIENT`; false deletes it, freezing the
/// metadata.
const METADATA_MUTABLE: bool = true;

const METADATA_CAP_RECIPIENT: address = @0x3e7a;

// === Public Types ===

/// One-time witness naming this package's currency; the Coin Registry proves it is unique.
public struct PRESALE_COIN has drop {}

// === Private Initialization ===

/// Creates the currency through Blast, which seals its `TreasuryCap`, and hands the sealed cap
/// to the publisher, who prepares the venue and opens the sale with it. The `Currency` goes to
/// the Coin Registry address; anyone may then share it with `coin_registry::finalize_registration`.
fun init(otw: PRESALE_COIN, ctx: &mut TxContext) {
    let (initializer, sealed_treasury_cap) = sale_token::new(
        otw,
        DECIMALS,
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        ctx,
    );

    transfer::public_transfer(sealed_treasury_cap, ctx.sender());
    if (METADATA_MUTABLE)
        transfer::public_transfer(initializer.finalize(ctx), METADATA_CAP_RECIPIENT)
    else initializer.finalize_and_delete_metadata_cap(ctx);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(PRESALE_COIN {}, ctx);
}

// === Imports ===

use blast_presale::sale_token;
