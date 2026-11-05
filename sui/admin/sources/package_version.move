// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// One package's publication proof, operational generation and pause bits, typed by its
/// one-time witness.
///
/// The consumer's initializer turns its one-time witness into an owned `Publication`, which
/// `package_admin::wrap` later converts into the shared `PackageVersion`, fully paused at
/// generation one. The consumer compiles its own generation constant and checks it with
/// `assert_current`; it also chooses which pause bits exist and pins its package witness, the one
/// type whose value its own code passes to clear pause bits or to borrow its Publisher. Setting
/// and clearing bits and advancing the generation are sealed here and reached only through
/// `package_admin`'s role-gated calls, so no package can build a second version or move a
/// generation by any other path.
module blast_admin::package_version;

// === Constants ===

const INITIAL_GENERATION: u64 = 1;

// === Public Types ===

/// Owned publication custody; it cannot supply the `PackageVersion` that operations require.
public struct Publication<phantom PackageMarker: drop> has key {
    id: UID,
    publisher: Publisher,
    valid_pause_bits: u8,
    package_witness: TypeName,
}

/// The package's shared operational generation and pause bits.
public struct PackageVersion<phantom PackageMarker: drop> has key {
    id: UID,
    /// The bits this package defines; every pause or unpause request must fall within them.
    valid_pause_bits: u8,
    paused: u8,
    /// The package witness: the exact type, with defining IDs, whose value only the package's own
    /// code passes to `package_admin::clear_pause_bits` and `package_admin::publisher`.
    package_witness: TypeName,
    /// The only generation whose compiled bytecode passes `assert_current`.
    generation: u64,
}

// === Public Functions ===

/// Claims the Publisher from the package's one-time witness, so a publication can only come into
/// existence inside that package's initializer; the framework rejects any other witness.
/// `valid_pause_bits` fixes the bits the package defines, and zero defines none.
/// `PackageWitness` pins the package witness, the one type that clears those bits and borrows the
/// Publisher: a struct the package defines, other than its marker, that only the package's own
/// code constructs and that it never returns or stores.
public fun new_publication<PackageMarker: drop, PackageWitness: drop>(
    otw: PackageMarker,
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): Publication<PackageMarker> {
    let package_witness = type_name::with_defining_ids<PackageWitness>();
    assert!(
        !package_witness.is_primitive()
            && type_name::original_id<PackageWitness>() == type_name::original_id<PackageMarker>()
            && package_witness != type_name::with_defining_ids<PackageMarker>(),
        blast_admin::errors::invalid_package_witness!(),
    );

    let publisher = sui::package::claim(otw, ctx);

    Publication { id: object::new(ctx), publisher, valid_pause_bits, package_witness }
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
    assert!(
        self.generation == compiled_generation,
        blast_admin::errors::operational_version_mismatch!(),
    );
}

/// Rejects an operation whose pause bit is set, before its lifecycle or economic checks. This is a
/// mask check only: a bit the package never defined is never set, so it never aborts.
public fun assert_not_paused<PackageMarker: drop>(self: &PackageVersion<PackageMarker>, bit: u8) {
    assert!((self.paused & bit) == 0, blast_admin::errors::paused!());
}

// === Package Functions ===

/// Consumes the publication into the Publisher and an unshared version at the first generation
/// with every defined bit paused.
public(package) fun into_version<PackageMarker: drop>(
    self: Publication<PackageMarker>,
    ctx: &mut TxContext,
): (Publisher, PackageVersion<PackageMarker>) {
    let Publication { id, publisher, valid_pause_bits, package_witness } = self;
    id.delete();

    let version = PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: valid_pause_bits,
        package_witness,
        generation: INITIAL_GENERATION,
    };

    (publisher, version)
}

/// Shares the version so the package's operations can read it.
public(package) fun share<PackageMarker: drop>(self: PackageVersion<PackageMarker>) {
    transfer::share_object(self);
}

/// Rejects clearing pause bits with any witness other than the package witness.
public(package) fun assert_unpause_witness<PackageMarker: drop, PackageWitness: drop>(
    self: &PackageVersion<PackageMarker>,
) {
    assert!(
        type_name::with_defining_ids<PackageWitness>() == self.package_witness,
        blast_admin::errors::wrong_unpause_witness!(),
    );
}

/// Rejects borrowing the Publisher with any witness other than the package witness.
public(package) fun assert_publisher_witness<PackageMarker: drop, PackageWitness: drop>(
    self: &PackageVersion<PackageMarker>,
) {
    assert!(
        type_name::with_defining_ids<PackageWitness>() == self.package_witness,
        blast_admin::errors::wrong_publisher_witness!(),
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

/// Moves to the next generation, which the newly committed bytecode compiles; bytecode compiling
/// any other generation then fails every `assert_current`. Aborts on overflow rather than wrap.
public(package) fun advance<PackageMarker: drop>(self: &mut PackageVersion<PackageMarker>) {
    let previous_generation = self.generation;
    self.generation = previous_generation + 1;

    blast_admin_events::operational_version_advanced<PackageMarker>(
        self.id.to_inner(),
        type_name::original_id<PackageMarker>(),
        previous_generation,
        self.generation,
    );
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
public fun new_for_testing<PackageMarker: drop, PackageWitness: drop>(
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): PackageVersion<PackageMarker> {
    PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: 0,
        package_witness: type_name::with_defining_ids<PackageWitness>(),
        generation: INITIAL_GENERATION,
    }
}

#[test_only]
public fun publisher_for_testing<PackageMarker: drop>(self: &Publication<PackageMarker>): &Publisher {
    &self.publisher
}

#[test_only]
public fun generation_for_testing<PackageMarker: drop>(self: &PackageVersion<PackageMarker>): u64 {
    self.generation
}

#[test_only]
public fun set_generation_for_testing<PackageMarker: drop>(
    self: &mut PackageVersion<PackageMarker>,
    generation: u64,
) {
    self.generation = generation;
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

use blast_admin::blast_admin_events;

use std::type_name::{Self, TypeName};

use sui::package::Publisher;
