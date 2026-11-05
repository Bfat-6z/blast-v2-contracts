// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The migrators package's publication.
///
/// `init` turns the one-time witness into `blast_admin`'s owned `Publication`, which the publisher
/// wraps with the package's `UpgradeCap` through `blast_admin::package_admin::wrap`; that shares
/// `PackageVersion<BLAST_MIGRATORS>` and `PackageAdmin<BLAST_MIGRATORS>`. Venues define no pause
/// bits, so the version starts unpaused and the package has no unpause. Residual risk: the package has no
/// emergency stop of its own. Migration stops with each product's migration pause bit and
/// `buyback_and_burn` with the vault's admin bit, but `prepare`, `collect_fees`, and
/// `settle_and_apply_fee_split` can be stopped only by advancing this package's generation through
/// a delayed upgrade, which retires every call to the old bytecode. Upgrades are scheduled,
/// authorized and committed through the generic `package_admin` under this package's own
/// `UpgradeAdmin<BLAST_MIGRATORS>` role. The products never import this package: each venue
/// redeems the `Migration` its product's own `migrate` returned earlier in the transaction.
module blast_migrators::blast_migrators;

// === Public Types ===

/// The package's one-time witness (OTW), typing its version, administration, and roles.
public struct BLAST_MIGRATORS() has drop;

/// The package witness `blast_admin` pins at publication, the one type that authorizes this
/// package's own administration calls such as unpause. Only this module could construct it, and it
/// is never stored or returned; the package defines no pause bits, so nothing constructs it.
public struct PackageWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_MIGRATORS, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, 0, ctx).keep(ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs publication initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_MIGRATORS(), ctx);
}

#[test_only]
/// An unshared current version with no pause bits, for focused tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_MIGRATORS> {
    package_version::new_for_testing<_, PackageWitness>(0, ctx)
}

// === Imports ===

use blast_admin::package_version::{Self, PackageVersion};
