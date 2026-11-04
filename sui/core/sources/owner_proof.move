// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the proof's abort location.
#[allow(lint(abort_without_constant))]
/// A package's sealed statement that the caller holds its creator authority over one sale, so a
/// vault can serve the sale's owner without importing either product. Each product keeps its own
/// authority (a curve-fee cap, a presale cap) and issues the proof after checking it; the proof
/// cannot be dropped, copied, or stored, so it authorizes exactly the one call that consumes it.
module blast_core::owner_proof;

// === Public Types ===

/// The caller holds the creator authority of sale `origin`, as the witness's package attests.
public struct OwnerProof {
    package_witness: TypeName,
    origin: ID,
}

// === Public Functions ===

/// Issues a proof for the sale `origin` under the issuing package's witness `PackageWitness`.
public fun new<PackageWitness: drop>(_: PackageWitness, origin: ID): OwnerProof {
    OwnerProof { package_witness: type_name::with_original_ids<PackageWitness>(), origin }
}

/// Consumes the proof, aborting unless it names `terms`' package witness and sale.
public fun assert_terms(self: OwnerProof, terms: &VaultTerms) {
    let OwnerProof { package_witness, origin } = self;

    assert!(
        package_witness == terms.package_witness() && origin == terms.origin(),
        blast_core::errors::wrong_owner!(),
    );
}

// === Imports ===

use blast_core::migration::VaultTerms;

use std::type_name::{Self, TypeName};
