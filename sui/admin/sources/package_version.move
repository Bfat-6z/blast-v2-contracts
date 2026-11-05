// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared package errors are zero-cost macros whose expanded literals trigger W04005.
#[allow(lint(abort_without_constant))]
/// One package's publication proof, version and pause bits, typed by its
/// one-time witness.
///
/// The consumer's initializer turns its one-time witness into an owned `Publication`, which
/// `package_admin::wrap` later converts into the shared `PackageVersion`, fully paused at
/// version one. The consumer compiles its own version constant and checks it with
/// `assert_current`; it also chooses which pause bits exist and pins its package witness, the one
/// type whose value its own code passes to clear pause bits or to borrow its Publisher. Setting
/// and clearing bits and advancing the version are sealed here and reached only through
/// `package_admin`'s role-gated calls, so no package can build a second version or move a
/// version by any other path.
module blast_admin::package_version;

// === Constants ===

const INITIAL_VERSION: u64 = 1;

// === Public Types ===

/// Owned publication custody; it cannot supply the `PackageVersion` that operations require. It has
/// no destructor: it holds the package's Publisher, whose one exit is `package_admin::wrap`.
public struct Publication<phantom OTW: drop> has key {
    id: UID,
    publisher: Publisher,
    valid_pause_bits: u8,
    package_witness: TypeName,
}

/// The package's shared version and pause bits. It has no destructor: every
/// version-gated call of the package reads it.
public struct PackageVersion<phantom OTW: drop> has key {
    id: UID,
    /// The bits this package defines; every pause or unpause request must fall within them.
    valid_pause_bits: u8,
    paused: u8,
    /// The package witness: the exact type, with defining IDs, whose value only the package's own
    /// code passes to `package_admin::clear_pause_bits`, `package_admin::publisher` and
    /// `package_admin::make_immutable`.
    package_witness: TypeName,
    /// The only version whose compiled bytecode passes `assert_current`.
    version: u64,
}

// === Public Functions ===

/// Claims the Publisher from the package's one-time witness, so a publication can only come into
/// existence inside that package's initializer; the framework rejects any other witness.
/// `valid_pause_bits` fixes the bits the package defines, and zero defines none.
/// `PackageWitness` pins the package witness, the one type that clears those bits and borrows the
/// Publisher: a struct the package defines, other than its OTW, that only the package's own
/// code constructs and that it never returns or stores.
public fun new_publication<OTW: drop, PackageWitness: drop>(
    otw: OTW,
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): Publication<OTW> {
    let package_witness = type_name::with_defining_ids<PackageWitness>();
    assert!(
        !package_witness.is_primitive()
            && type_name::original_id<PackageWitness>() == type_name::original_id<OTW>()
            && package_witness != type_name::with_defining_ids<OTW>(),
        blast_admin::errors::invalid_package_witness!(),
    );

    let publisher = sui::package::claim(otw, ctx);

    Publication { id: object::new(ctx), publisher, valid_pause_bits, package_witness }
}

/// Transfers the publication to the transaction sender, who later wraps it with the
/// package's `UpgradeCap`.
public fun keep<OTW: drop>(self: Publication<OTW>, ctx: &mut TxContext) {
    transfer::transfer(self, ctx.sender());
}

/// Rejects callable bytecode whose compiled version is not the active one.
public fun assert_current<OTW: drop>(
    self: &PackageVersion<OTW>,
    compiled_version: u64,
) {
    assert!(
        self.version == compiled_version,
        blast_admin::errors::version_mismatch!(),
    );
}

/// Rejects an operation whose pause bit is set, before its lifecycle or economic checks. This is a
/// mask check only: a bit the package never defined is never set, so it never aborts.
public fun assert_not_paused<OTW: drop>(self: &PackageVersion<OTW>, bit: u8) {
    assert!(!self.is_paused(bit), blast_admin::errors::paused!());
}

// Readers

/// The active version; only bytecode compiling it passes `assert_current`.
public fun version<OTW: drop>(self: &PackageVersion<OTW>): u64 {
    self.version
}

/// The pause bits the package defines.
public fun valid_pause_bits<OTW: drop>(self: &PackageVersion<OTW>): u8 {
    self.valid_pause_bits
}

/// The pause bits currently set.
public fun paused<OTW: drop>(self: &PackageVersion<OTW>): u8 {
    self.paused
}

/// True when any of `bits` is set.
public fun is_paused<OTW: drop>(self: &PackageVersion<OTW>, bits: u8): bool {
    (self.paused & bits) != 0
}

/// The package witness type, with defining IDs, pinned at publication.
public fun package_witness<OTW: drop>(self: &PackageVersion<OTW>): TypeName {
    self.package_witness
}

/// The pause bits the publication will define once wrapped.
public fun publication_valid_pause_bits<OTW: drop>(
    self: &Publication<OTW>,
): u8 {
    self.valid_pause_bits
}

/// The ID of the Publisher the publication holds.
public fun publication_publisher_id<OTW: drop>(self: &Publication<OTW>): ID {
    object::id(&self.publisher)
}

/// The package witness type, with defining IDs, the publication pins.
public fun publication_package_witness<OTW: drop>(
    self: &Publication<OTW>,
): TypeName {
    self.package_witness
}

// === Package Functions ===

/// Consumes the publication into the Publisher and an unshared version at the first version
/// with every defined bit paused.
public(package) fun into_version<OTW: drop>(
    self: Publication<OTW>,
    ctx: &mut TxContext,
): (Publisher, PackageVersion<OTW>) {
    let Publication { id, publisher, valid_pause_bits, package_witness } = self;
    id.delete();

    let version = PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: valid_pause_bits,
        package_witness,
        version: INITIAL_VERSION,
    };

    (publisher, version)
}

/// Records the new version beside the administration `package_admin_id` that wraps it, then shares it
/// so the package's operations can read it.
public(package) fun share<OTW: drop>(
    self: PackageVersion<OTW>,
    package_admin_id: ID,
) {
    blast_admin_events::package_version_created<OTW>(
        self.id.to_inner(),
        package_admin_id,
        self.valid_pause_bits,
        self.paused,
        self.package_witness,
        self.version,
    );

    transfer::share_object(self);
}

/// Rejects clearing pause bits with any witness other than the package witness.
public(package) fun assert_unpause_witness<OTW: drop, PackageWitness: drop>(
    self: &PackageVersion<OTW>,
) {
    assert!(
        type_name::with_defining_ids<PackageWitness>() == self.package_witness,
        blast_admin::errors::wrong_unpause_witness!(),
    );
}

/// Rejects borrowing the Publisher, or ending upgrades, with any witness other than the package
/// witness.
public(package) fun assert_package_witness<OTW: drop, PackageWitness: drop>(
    self: &PackageVersion<OTW>,
) {
    assert!(
        type_name::with_defining_ids<PackageWitness>() == self.package_witness,
        blast_admin::errors::wrong_package_witness!(),
    );
}

/// Sets the requested bits, at least one of which must be clear.
public(package) fun set_pause_bits<OTW: drop>(
    self: &mut PackageVersion<OTW>,
    bits: u8,
) {
    self.assert_valid_pause_bits(bits);
    assert!((self.paused | bits) != self.paused, blast_admin::errors::pause_unchanged!());

    self.paused = self.paused | bits;

    blast_admin_events::paused<OTW>(self.id.to_inner(), bits, self.paused);
}

/// Clears the requested bits, at least one of which must be set.
public(package) fun clear_pause_bits<OTW: drop>(
    self: &mut PackageVersion<OTW>,
    bits: u8,
) {
    self.assert_valid_pause_bits(bits);
    assert!((self.paused & bits) != 0, blast_admin::errors::pause_unchanged!());

    self.paused = self.paused ^ (self.paused & bits);

    blast_admin_events::unpaused<OTW>(self.id.to_inner(), bits, self.paused);
}

/// Moves to the next version, which the newly committed bytecode compiles; bytecode compiling
/// any other version then fails every `assert_current`. Aborts on overflow rather than wrap.
public(package) fun advance<OTW: drop>(self: &mut PackageVersion<OTW>) {
    let previous_version = self.version;
    self.version = previous_version + 1;

    blast_admin_events::version_advanced<OTW>(
        self.id.to_inner(),
        type_name::original_id<OTW>(),
        previous_version,
        self.version,
    );
}

// === Private Functions ===

fun assert_valid_pause_bits<OTW: drop>(self: &PackageVersion<OTW>, bits: u8) {
    assert!(
        bits != 0 && (bits & self.valid_pause_bits) == bits,
        blast_admin::errors::invalid_pause_bits!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Creates an unshared, unpaused version for consumer tests that need no publication flow.
public fun new_for_testing<OTW: drop, PackageWitness: drop>(
    valid_pause_bits: u8,
    ctx: &mut TxContext,
): PackageVersion<OTW> {
    PackageVersion {
        id: object::new(ctx),
        valid_pause_bits,
        paused: 0,
        package_witness: type_name::with_defining_ids<PackageWitness>(),
        version: INITIAL_VERSION,
    }
}

#[test_only]
public fun publisher_for_testing<OTW: drop>(
    self: &Publication<OTW>,
): &Publisher {
    &self.publisher
}

#[test_only]
public fun version_for_testing<OTW: drop>(self: &PackageVersion<OTW>): u64 {
    self.version
}

#[test_only]
public fun set_version_for_testing<OTW: drop>(
    self: &mut PackageVersion<OTW>,
    version: u64,
) {
    self.version = version;
}

#[test_only]
public fun paused_for_testing<OTW: drop>(self: &PackageVersion<OTW>): u8 {
    self.paused
}

#[test_only]
public fun valid_pause_bits_for_testing<OTW: drop>(
    self: &PackageVersion<OTW>,
): u8 {
    self.valid_pause_bits
}

// === Imports ===

public use fun publication_valid_pause_bits as Publication.valid_pause_bits;
public use fun publication_package_witness as Publication.package_witness;
public use fun publication_publisher_id as Publication.publisher_id;

use blast_admin::blast_admin_events;

use std::type_name::{Self, TypeName};

use sui::package::Publisher;
