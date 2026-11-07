// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Generated Meme with a burn-only supply for the real venue buyback tests.
module ptb_burnable_project::burnable_token;

// === Public Types ===

public struct BURNABLE_TOKEN has drop {}

// === Private Initialization ===

/// Creates the currency and its launch ticket and hands the ticket to the publisher.
fun init(otw: BURNABLE_TOKEN, ctx: &mut TxContext) {
    let (ticket, sealed_treasury_cap) = launch_ticket::new(
        otw,
        9,
        b"PTBBURN".to_string(),
        b"PTB migration".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(ctx.sender()),
        true,
        0,
        ctx,
    );

    transfer::public_transfer(ticket, ctx.sender());
    transfer::public_transfer(sealed_treasury_cap, ctx.sender());
}

// === Imports ===

use blast_fun::{creator_authority, launch_ticket};
