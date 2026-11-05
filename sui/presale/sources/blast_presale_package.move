// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The presale's publication and the one constructor of its package witness.
///
/// Publication hands the deployer an owned `Publication<BLAST_PRESALE_PACKAGE>`, which
/// `blast_admin::package_admin::wrap` turns into the shared `PackageAdmin<BLAST_PRESALE_PACKAGE>`
/// and the shared `PackageVersion<BLAST_PRESALE_PACKAGE>`, fully paused. Pausing, upgrades, and
/// immutability go through `blast_admin::package_admin` under the package-scoped roles
/// `PauseAdmin<BLAST_PRESALE_PACKAGE>`, `UpgradeAdmin<BLAST_PRESALE_PACKAGE>`, and
/// `CancelAdmin<BLAST_PRESALE_PACKAGE>`.
///
/// The fee and creation policies start with zero notices so Blast configures them while the
/// package is paused; `creation_policy::unpause` refuses until every notice is guarded, then clears
/// bits with the package witness. It lives beside the policies it reads because they name
/// `BLAST_PRESALE_PACKAGE`, so this module cannot import them.
module blast_presale::blast_presale_package;

// === Public Types ===

/// The package's one-time witness (OTW), typing its version, publication, and roles.
public struct BLAST_PRESALE_PACKAGE() has drop;

/// The presale's one package witness, pinned at publication. It seals each sale's protocol-fee
/// ledger, migration, vault terms and owner proofs, and clears pause bits through the generic
/// administration. Only this module constructs it, through the package-only `package_witness`;
/// nothing stores it or returns it outside the package.
public struct PackageWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_PRESALE_PACKAGE, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
}

// === Package Functions ===

/// The package witness, for `blast_presale`'s ledger, hand-off and owner proofs and for
/// `creation_policy::unpause`.
public(package) fun package_witness(): PackageWitness {
    PackageWitness()
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_PRESALE_PACKAGE(), ctx);
}

#[test_only]
/// An unshared, unpaused version for tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_PRESALE_PACKAGE> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

#[test_only]
/// Package administration around a test Publisher and upgrade cap, with the 48-hour notice.
public fun package_admin_for_testing(ctx: &mut TxContext): PackageAdmin<BLAST_PRESALE_PACKAGE> {
    blast_admin::package_admin::new_for_testing(
        sui::package::test_claim(BLAST_PRESALE_PACKAGE(), ctx),
        sui::package::test_publish(@blast_presale.to_id(), ctx),
        ctx,
    )
}

// === Imports ===

use blast_admin::{package_admin::PackageAdmin, package_version::{Self, PackageVersion}};

use blast_presale::constants;
