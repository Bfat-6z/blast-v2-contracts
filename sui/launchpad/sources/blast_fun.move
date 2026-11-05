// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The launchpad's publication and its package witness.
///
/// Publication hands the deployer an owned `Publication<BLAST_FUN>`, which
/// `blast_admin::package_admin::wrap` turns into the shared `PackageAdmin<BLAST_FUN>` and the
/// shared `PackageVersion<BLAST_FUN>`, fully paused. Pausing, upgrades, and immutability go through
/// `blast_admin::package_admin` under the package-scoped roles `PauseAdmin<BLAST_FUN>`,
/// `UpgradeAdmin<BLAST_FUN>`, and `CancelAdmin<BLAST_FUN>`.
///
/// The publication pins `PackageWitness`, the one witness the package passes wherever a sealed
/// call must name the launchpad: the launch fee ledger, migration hand-off, vault terms and owner
/// proofs, and the generic administration's pause release. `launch_config::unpause` releases pause
/// bits once every launchpad notice is guarded; it lives beside the configurations it reads, which
/// name `BLAST_FUN`, so this module cannot import them.
module blast_fun::blast_fun;

// === Public Types ===

/// The package's one-time witness and the marker of its version, publication, and roles.
public struct BLAST_FUN() has drop;

/// The launchpad's package witness. Only this package constructs it, through `package_witness`;
/// every caller passes it straight into the sealing or release call, and no function stores it or
/// returns it outside this package.
public struct PackageWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_FUN, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
}

// === Package Functions ===

/// The package witness, for the launchpad's own sealing and release calls.
public(package) fun package_witness(): PackageWitness {
    PackageWitness()
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_FUN(), ctx);
}

#[test_only]
/// An unshared, unpaused version for tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_FUN> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

#[test_only]
/// Package administration around a test Publisher and upgrade cap, with the 48-hour notice.
public fun package_admin_for_testing(
    ctx: &mut TxContext,
): blast_admin::package_admin::PackageAdmin<BLAST_FUN> {
    blast_admin::package_admin::new_for_testing(
        sui::package::test_claim(BLAST_FUN(), ctx),
        sui::package::test_publish(@blast_fun.to_id(), ctx),
        ctx,
    )
}

#[test_only]
/// Clears `bits` through the generic administration without the configuration notice checks.
public fun clear_pause_bits_for_testing(
    package_version: &mut PackageVersion<BLAST_FUN>,
    bits: u8,
    ctx: &mut TxContext,
) {
    let package_admin = package_admin_for_testing(ctx);
    let unpause_admin = blast_admin::blast_acl::witness_for_testing<
        blast_admin::package_admin::UnpauseAdmin<BLAST_FUN>,
    >();
    package_admin.clear_pause_bits(&unpause_admin, PackageWitness(), package_version, bits);
    std::unit_test::destroy(package_admin);
}

// === Imports ===

use blast_admin::package_version::{Self, PackageVersion};

use blast_fun::constants;
