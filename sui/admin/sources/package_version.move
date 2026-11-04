// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// One package's publication proof, operational generation and pause bits, typed by its
/// one-time witness.
///
/// The consumer's initializer turns its one-time witness into an owned `Publication`, which
/// `package_admin::wrap` later converts into the shared `PackageVersion`, fully paused. The
/// consumer compiles its own generation constant and checks it with `assert_current`; it also
/// chooses which pause bits exist and pins the one witness type its own unpause passes when
/// clearing them. Setting and clearing bits and advancing the generation are sealed here and
/// reached only through `package_admin`'s role-gated calls.
module blast_admin::package_version;

// === Public Types ===

/// Owned publication custody; it cannot supply the `PackageVersion` that operations require.
public struct Publication<phantom PackageMarker: drop> has key {
    id: UID,
    publisher: Publisher,
    valid_pause_bits: u8,
    unpause_witness: TypeName,
    generation: OperationalVersion<PackageMarker>,
}

/// The package's shared operational generation and pause bits.
public struct PackageVersion<phantom PackageMarker: drop> has key {
    id: UID,
    /// The bits this package defines; every pause or unpause request must fall within them.
    valid_pause_bits: u8,
    paused: u8,
    /// The exact type, with defining IDs, whose value the package's own unpause passes to
    /// `package_admin::clear_pause_bits`.
    unpause_witness: TypeName,
    generation: OperationalVersion<PackageMarker>,
}

// === Public Functions ===

/// Claims the Publisher and seeds the first generation from the package's one-time witness,
/// so a publication can only come into existence inside that package's initializer.
/// `valid_pause_bits` fixes the bits the package defines, and zero defines none.
/// `UnpauseWitness` pins the one type that can clear them: a struct the package defines, other
/// than its marker, that it constructs only inside its own unpause and never returns or stores.
public fun new_publication<PackageMarker: drop, UnpauseWitness: drop>(
    otw: PackageMarker,
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): Publication<PackageMarker> {
    let generation = operational_version::new(&otw);
    let unpause_witness = type_name::with_defining_ids<UnpauseWitness>();
    assert!(
        !unpause_witness.is_primitive()
            && type_name::original_id<UnpauseWitness>() == type_name::original_id<PackageMarker>()
            && unpause_witness != type_name::with_defining_ids<PackageMarker>(),
        blast_admin::errors::invalid_package_witness!(),
    );

    let publisher = sui::package::claim(otw, ctx);

    Publication { id: object::new(ctx), publisher, valid_pause_bits, unpause_witness, generation }
}

/// Transfers the publication to the transaction sender, who later wraps it with the
/// package's `UpgradeCap`.
public fun keep<PackageMarker: drop>(self: Publication<PackageMarker>, ctx: &mut TxContext) {
    transfer::transfer(self, ctx.sender());
}

/// Rejects callable bytecode whose compiled generation is not the active one.
public fun assert_current<PackageMarker: drop>(
    self: &PackageVersion<PackageMarker>,
    compiled_generation: u64,
) {
    self.generation.assert_current(compiled_generation);
}

/// Rejects an operation whose pause bit is set, before its lifecycle or economic checks.
public fun assert_not_paused<PackageMarker: drop>(self: &PackageVersion<PackageMarker>, bit: u8) {
    assert!((self.paused & bit) == 0, blast_admin::errors::paused!());
}

// === Package Functions ===

/// Consumes the publication into the Publisher and an unshared version with every defined
/// bit paused.
public(package) fun into_version<PackageMarker: drop>(
    self: Publication<PackageMarker>,
    ctx: &mut TxContext,
): (Publisher, PackageVersion<PackageMarker>) {
    let Publication { id, publisher, valid_pause_bits, unpause_witness, generation } = self;
    id.delete();

    let version = PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: valid_pause_bits,
        unpause_witness,
        generation,
    };

    (publisher, version)
}

/// Shares the version so the package's operations can read it.
public(package) fun share<PackageMarker: drop>(self: PackageVersion<PackageMarker>) {
    transfer::share_object(self);
}

/// Rejects any witness other than the exact type the package pinned at publication.
public(package) fun assert_unpause_witness<PackageMarker: drop, PackageWitness: drop>(
    self: &PackageVersion<PackageMarker>,
) {
    assert!(
        type_name::with_defining_ids<PackageWitness>() == self.unpause_witness,
        blast_admin::errors::wrong_unpause_witness!(),
    );
}

/// Sets the requested bits, at least one of which must be clear.
public(package) fun set_pause_bits<PackageMarker: drop>(
    self: &mut PackageVersion<PackageMarker>,
    bits: u8,
) {
    self.assert_valid_pause_bits(bits);
    assert!((self.paused | bits) != self.paused, blast_admin::errors::pause_unchanged!());

    self.paused = self.paused | bits;

    blast_admin_events::paused<PackageMarker>(self.id.to_inner(), bits, self.paused);
}

/// Clears the requested bits, at least one of which must be set.
public(package) fun clear_pause_bits<PackageMarker: drop>(
    self: &mut PackageVersion<PackageMarker>,
    bits: u8,
) {
    self.assert_valid_pause_bits(bits);
    assert!((self.paused & bits) != 0, blast_admin::errors::pause_unchanged!());

    self.paused = self.paused ^ (self.paused & bits);

    blast_admin_events::unpaused<PackageMarker>(self.id.to_inner(), bits, self.paused);
}

/// The generation after the active one; aborts at the end of the generation range.
public(package) fun next_generation<PackageMarker: drop>(self: &PackageVersion<PackageMarker>): u64 {
    self.generation.next_generation()
}

/// Advances to `next_generation`, which must be exactly the generation after the active one.
public(package) fun advance<PackageMarker: drop>(
    self: &mut PackageVersion<PackageMarker>,
    next_generation: u64,
) {
    self.generation.advance(&self.id, next_generation);
}

// === Private Functions ===

fun assert_valid_pause_bits<PackageMarker: drop>(self: &PackageVersion<PackageMarker>, bits: u8) {
    assert!(
        bits != 0 && (bits & self.valid_pause_bits) == bits,
        blast_admin::errors::invalid_pause_bits!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Creates an unshared, unpaused version for consumer tests that need no publication flow.
public fun new_for_testing<PackageMarker: drop, UnpauseWitness: drop>(
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): PackageVersion<PackageMarker> {
    PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: 0,
        unpause_witness: type_name::with_defining_ids<UnpauseWitness>(),
        generation: operational_version::new_for_testing(),
    }
}

#[test_only]
public fun publisher_for_testing<PackageMarker: drop>(self: &Publication<PackageMarker>): &Publisher {
    &self.publisher
}

#[test_only]
public fun generation_for_testing<PackageMarker: drop>(self: &PackageVersion<PackageMarker>): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
public fun set_generation_for_testing<PackageMarker: drop>(
    self: &mut PackageVersion<PackageMarker>,
    generation: u64,
) {
    self.generation.set_generation_for_testing(generation);
}

#[test_only]
public fun paused_for_testing<PackageMarker: drop>(self: &PackageVersion<PackageMarker>): u8 {
    self.paused
}

#[test_only]
public fun valid_pause_bits_for_testing<PackageMarker: drop>(
    self: &PackageVersion<PackageMarker>,
): u8 {
    self.valid_pause_bits
}

// === Imports ===

use blast_admin::{blast_admin_events, operational_version::{Self, OperationalVersion}};

use std::type_name::{Self, TypeName};

use sui::package::Publisher;
