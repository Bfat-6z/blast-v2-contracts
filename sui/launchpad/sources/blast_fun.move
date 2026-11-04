// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the package module's abort location.
#[allow(lint(abort_without_constant))]
/// The launchpad's publication and the one constructor of its unpause witness.
///
/// Publication hands the deployer an owned `Publication<BLAST_FUN>`, which
/// `blast_admin::package_admin::wrap` turns into the shared `PackageAdmin<BLAST_FUN>` and the
/// shared `PackageVersion<BLAST_FUN>`, fully paused. Pausing, upgrades, and immutability go through
/// `blast_admin::package_admin` under the package-scoped roles `PauseAdmin<BLAST_FUN>`,
/// `UpgradeAdmin<BLAST_FUN>`, and `CancelAdmin<BLAST_FUN>`.
///
/// The launch and runtime configurations start with zero notices so Blast configures them while
/// the package is paused; `launch_config::unpause` refuses until every notice is guarded. It lives
/// beside the configurations it reads because they name `BLAST_FUN`, so this module cannot import
/// them.
module blast_fun::blast_fun;

// === Public Types ===

/// The package's one-time witness and the marker of its version, publication, and roles.
public struct BLAST_FUN() has drop;

/// The witness `clear_pause_bits` passes to the generic administration; only this module
/// constructs it.
public struct UnpauseWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_FUN, ctx: &mut TxContext) {
    package_version::new_publication<_, UnpauseWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
}

// === Package Functions ===

/// Clears the requested pause bits through the generic administration, passing the witness this
/// package pinned at publication. Only `launch_config::unpause` calls it, after checking every
/// launchpad notice; the witness never leaves this module.
public(package) fun clear_pause_bits(
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_FUN>>,
    package_admin: &PackageAdmin<BLAST_FUN>,
    package_version: &mut PackageVersion<BLAST_FUN>,
    bits: u8,
) {
    package_admin.clear_pause_bits(unpause_admin, UnpauseWitness(), package_version, bits);
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
    package_version::new_for_testing<_, UnpauseWitness>(constants::valid_pause_bits!(), ctx)
}

#[test_only]
/// Package administration around a test Publisher and upgrade cap, with the 48-hour notice.
public fun package_admin_for_testing(ctx: &mut TxContext): PackageAdmin<BLAST_FUN> {
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
    clear_pause_bits(&blast_admin::blast_acl::witness_for_testing(), &package_admin, package_version, bits);
    std::unit_test::destroy(package_admin);
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::{Self, PackageVersion}
};

use blast_fun::constants;
