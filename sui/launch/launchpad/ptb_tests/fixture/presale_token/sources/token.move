// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sale-token stand-in. The harness publishes this package once per presale, so every sale has
/// its own one-time-witness currency, with its `TreasuryCap` sealed under the presale from birth.
module ptb_presale_token::token;

// === Public Types ===

public struct TOKEN has drop {}

// === Private Initialization ===

/// Registers the currency through the presale, which seals its cap, and hands the sealed cap and
/// the metadata cap to the publisher.
fun init(otw: TOKEN, ctx: &mut TxContext) {
    let (initializer, sealed_treasury_cap) = sale_token::new(
        otw,
        9,
        b"PTB".to_string(),
        b"PTB presale".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );

    transfer::public_transfer(sealed_treasury_cap, ctx.sender());
    transfer::public_transfer(initializer.finalize(ctx), ctx.sender());
}

// === Imports ===

use blast_presale::sale_token;
