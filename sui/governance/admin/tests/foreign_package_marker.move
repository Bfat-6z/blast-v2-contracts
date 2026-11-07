// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Supplies a Publisher whose original package address is outside `blast_admin`.
module 0xf::foreign_package_marker;

// === Test-Only Types ===

public struct FOREIGN_PACKAGE_MARKER has drop {}

/// A droppable witness from a package other than the OTW's under test.
public struct ForeignWitness() has drop;

// === Test Helpers ===

public fun publisher(ctx: &mut TxContext): Publisher {
    package::test_claim(FOREIGN_PACKAGE_MARKER {}, ctx)
}

public fun witness(): ForeignWitness {
    ForeignWitness()
}

// === Imports ===

use sui::package::{Self, Publisher};
