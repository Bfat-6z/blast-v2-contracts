// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Canonical publication custody and operational generation.
///
/// The one-time witness seeds the generation and claims the Publisher. Both stay in owned
/// publication custody until package administration seals the native capabilities.
module blast_presale::blast_presale_package;

// === Constants ===

/// Current package generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Types ===

/// The requested bits and resulting pause mask.
public struct Paused has copy, drop {
    bits: u8,
    paused: u8
}
/// The released bits and resulting pause mask.
public struct Unpaused has copy, drop {
    bits: u8,
    paused: u8
}

/// One-time witness: it seeds the package generation and claims this package's Publisher.
public struct BLAST_PRESALE_PACKAGE() has drop;

/// Publication-only custody; it cannot supply the PackageVersion required by presale activity.
public struct Publication has key {
    id: UID,
    publisher: Publisher,
    generation: OperationalVersion<BLAST_PRESALE_PACKAGE>,
}

/// Singleton operational package generation.
public struct PackageVersion has key {
    id: UID,
    paused: u8,
    generation: OperationalVersion<BLAST_PRESALE_PACKAGE>,
}

// === Private Initialization ===

fun init(otw: BLAST_PRESALE_PACKAGE, ctx: &mut TxContext) {
    let generation = operational_version::new(&otw);
    let publisher = sui::package::claim(otw, ctx);

    transfer::transfer(Publication { id: object::new(ctx), publisher, generation }, ctx.sender());
}

// === Public Functions ===

/// Freezes selected operations immediately; does not authorize unpausing.
public fun pause(self: &mut PackageVersion, _: &AdminWitness<PauseAdmin>, bits: u8) {
    self.assert_current();

    assert!(
        bits != 0 && (bits & constants::valid_pause_bits!()) == bits,
        blast_presale::errors::invalid_pause_bits!(),
    );
    assert!((self.paused | bits) != self.paused, blast_presale::errors::pause_unchanged!());
    self.paused = self.paused | bits;

    sui::event::emit(Paused { bits, paused: self.paused });
}

// === Package Functions ===

/// Clears only the requested bits once `package_admin::unpause` has checked every notice.
public(package) fun clear_pause_bits(self: &mut PackageVersion, bits: u8) {
    assert!(
        bits != 0 && (bits & constants::valid_pause_bits!()) == bits,
        blast_presale::errors::invalid_pause_bits!(),
    );
    assert!((self.paused & bits) != 0, blast_presale::errors::pause_unchanged!());
    self.paused = self.paused ^ (self.paused & bits);

    sui::event::emit(Unpaused { bits, paused: self.paused });
}

/// Rejects a paused operation before its lifecycle or economic checks.
public(package) fun assert_not_paused(self: &PackageVersion, bit: u8) {
    assert!((self.paused & bit) == 0, blast_presale::errors::paused!());
}

/// Consumes the unique publication for package-admin custody intake.
public(package) fun destroy(
    self: Publication,
): (Publisher, OperationalVersion<BLAST_PRESALE_PACKAGE>) {
    let Publication { id, publisher, generation } = self;
    id.delete();

    (publisher, generation)
}

/// Publishes the usable generation in the same transaction that seals capability custody.
public(package) fun share_version(
    generation: OperationalVersion<BLAST_PRESALE_PACKAGE>,
    ctx: &mut TxContext,
) {
    transfer::share_object(PackageVersion {
        paused: constants::valid_pause_bits!(),
        id: object::new(ctx),
        generation
    });
}

/// Rejects callable bytecode from every package generation except the active one.
public(package) fun assert_current(self: &PackageVersion) {
    self.generation.assert_current(PACKAGE_VERSION);
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &PackageVersion) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the shared generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut PackageVersion) {
    self.generation.advance(&self.id, NEXT_PACKAGE_VERSION);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_PRESALE_PACKAGE(), ctx);
}

#[test_only]
/// Creates unshared current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    let otw = BLAST_PRESALE_PACKAGE();

    PackageVersion { paused: 0, id: object::new(ctx), generation: operational_version::new(&otw) }
}

#[test_only]
/// Inspects the canonical Publisher retained by initialization without releasing it.
public fun publisher_for_publication_testing(self: &Publication): &Publisher {
    &self.publisher
}

#[test_only]
/// Forces a package generation for guard and cutover tests.
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
/// Returns the stored package generation for transition assertions.
public fun version_for_testing(self: &PackageVersion): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut PackageVersion) {
    self.advance();
}

#[test_only]
/// Claims an additional canonical-module Publisher for package-administration fixture inputs.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(BLAST_PRESALE_PACKAGE(), ctx)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, operational_version::{Self, OperationalVersion}};

use blast_presale::{blast_presale_domain::PauseAdmin, constants};

use sui::package::Publisher;
