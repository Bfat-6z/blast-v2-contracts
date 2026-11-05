// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Canonical package one-time witness (OTW) used by version and custody tests.
module 0xa::package_marker;

// === Test-Only Types ===

public struct PACKAGE_MARKER has drop {}

/// A key type from the OTW's package, for provenance-gated feature tests such as Display.
public struct Receipt has key {
    id: UID,
}

/// The package witness only this OTW's package constructs, for package-gated calls.
public struct PackageWitness() has drop;

// === Test Helpers ===

public fun otw(): PACKAGE_MARKER {
    PACKAGE_MARKER {}
}

public fun package_witness(): PackageWitness {
    PackageWitness()
}
