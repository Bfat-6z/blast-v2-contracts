// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Typed replay facts for Cetus pool reservations. Vault custody, LP-fee collection, auto-LP,
/// buybacks, and holder rewards are recorded by `blast_vault`'s events.
module blast_fun_migrators::blast_events;

// === Public Types ===

/// Records Cetus pool creation reserved for one pair at the tick spacing its migration uses.
public struct CetusPoolReserved has copy, drop {
    meme: TypeName,
    quote: TypeName,
    pool_creation_cap_id: ID,
    tick_spacing: u32,
}

// === Package Functions ===

/// Emits the Cetus pair reservation made while preparing a coin.
public(package) fun cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id: ID, tick_spacing: u32) {
    sui::event::emit(CetusPoolReserved {
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        pool_creation_cap_id,
        tick_spacing,
    });
}

// === Imports ===

use std::type_name::{Self, TypeName};
