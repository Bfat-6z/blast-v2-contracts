// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the proof's abort location.
#[allow(lint(abort_without_constant))]
/// A product's sealed statement that the caller holds its creator authority over one sale, so a
/// vault can serve the sale's owner without importing either product. Each product keeps its own
/// authority (a curve-fee cap, a presale cap) and issues the proof after checking it; the proof
/// cannot be dropped, copied, or stored, so it authorizes exactly the one call that consumes it.
module blast_core::owner_proof;

// === Public Types ===

public struct OwnerProof {
    product: TypeName,
    origin: ID,
}

// === Public Functions ===

/// Issues a proof for the sale `origin` under the product witness `Product`.
public fun prove<Product: drop>(_: Product, origin: ID): OwnerProof {
    OwnerProof { product: type_name::with_original_ids<Product>(), origin }
}

/// Consumes the proof, aborting unless it names `terms`' product and sale.
public fun verify(self: OwnerProof, terms: &VaultTerms) {
    let OwnerProof { product, origin } = self;

    assert!(
        product == terms.product() && origin == terms.origin(),
        blast_core::errors::wrong_owner!(),
    );
}

// === Imports ===

use blast_core::migration::VaultTerms;

use std::type_name::{Self, TypeName};
