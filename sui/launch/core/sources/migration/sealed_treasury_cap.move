// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the seal's abort location.
#[allow(lint(abort_without_constant))]
/// A coin's `TreasuryCap` sealed by the product that created the currency, from publication until
/// that product's `new` opens it.
///
/// The seal closes the window in which a coin's creator could mint before a sale starts: between
/// publication and the venue's preparation of the coin, which borrows the cap to reserve the
/// pair's pool creation, the holder of a sealed cap can only hand it to a venue the sealing
/// product admits. The product checks its own venue allowlist and issues a `VenueAdmission` under
/// its package witness; the venue presents the admission with its own witness to borrow the cap.
/// Only the sealing product's witness opens the seal, so the raw cap never reaches a creator's
/// transaction, and a venue reaches it only through code the product admitted.
///
/// Every witness is identified by `type_name::with_original_ids`, as in `migration`.
module blast_core::sealed_treasury_cap;

// === Public Types ===

/// A coin's `TreasuryCap` under the seal of one product's package witness. Wallet-held like the
/// cap it replaces, and transferable; whoever starts the sale needs it.
public struct SealedTreasuryCap<phantom Coin> has key, store {
    id: UID,
    /// The original type of the package witness that sealed the cap: its admissions borrow the
    /// cap and only its witness opens the seal.
    package_witness: TypeName,
    treasury_cap: TreasuryCap<Coin>,
}

/// A product's proof, issued under its package witness after checking its own allowlist, that it
/// admits the venue `venue`. Droppable and ephemeral: a venue presents it to borrow a cap the same
/// product sealed, within the transaction that obtained it.
public struct VenueAdmission has drop {
    package_witness: TypeName,
    venue: TypeName,
}

// === Public Functions ===

/// Seals `treasury_cap` under `PackageWitness`, the package witness of the product that will open
/// it.
public fun new<Coin, PackageWitness: drop>(
    _: PackageWitness,
    treasury_cap: TreasuryCap<Coin>,
    ctx: &mut TxContext,
): SealedTreasuryCap<Coin> {
    SealedTreasuryCap {
        id: object::new(ctx),
        package_witness: type_name::with_original_ids<PackageWitness>(),
        treasury_cap,
    }
}

/// A product's admission of the venue `Venue`, issued under its `PackageWitness`. The product
/// checks its own venue allowlist first; the admission carries no check of its own.
public fun venue_admission<Venue: drop, PackageWitness: drop>(_: PackageWitness): VenueAdmission {
    VenueAdmission {
        package_witness: type_name::with_original_ids<PackageWitness>(),
        venue: type_name::with_original_ids<Venue>(),
    }
}

/// Borrows the sealed cap for the venue `Venue`, which must hold `admission` from the product
/// that sealed it. A reference result stays inside Move code, so only the venue's own call reaches
/// the cap.
public fun treasury_cap_mut<Coin, Venue: drop>(
    self: &mut SealedTreasuryCap<Coin>,
    admission: VenueAdmission,
    _: Venue,
): &mut TreasuryCap<Coin> {
    assert!(
        admission.package_witness == self.package_witness,
        blast_core::errors::wrong_package_witness!(),
    );
    assert!(
        admission.venue == type_name::with_original_ids<Venue>(),
        blast_core::errors::venue_not_admitted!(),
    );

    &mut self.treasury_cap
}

/// Opens the seal under the package witness that made it, releasing the cap to the product.
public fun into_treasury_cap<Coin, PackageWitness: drop>(
    self: SealedTreasuryCap<Coin>,
    _: PackageWitness,
): TreasuryCap<Coin> {
    assert!(
        self.package_witness == type_name::with_original_ids<PackageWitness>(),
        blast_core::errors::wrong_package_witness!(),
    );

    let SealedTreasuryCap { id, package_witness: _, treasury_cap } = self;
    id.delete();

    treasury_cap
}

/// The original type of the package witness that sealed the cap.
public fun package_witness<Coin>(self: &SealedTreasuryCap<Coin>): TypeName {
    self.package_witness
}

/// The ID of the sealed `TreasuryCap`, which the product records when it opens the seal.
public fun treasury_cap_id<Coin>(self: &SealedTreasuryCap<Coin>): ID {
    object::id(&self.treasury_cap)
}

/// The sealed cap's total supply.
public fun total_supply<Coin>(self: &SealedTreasuryCap<Coin>): u64 {
    self.treasury_cap.total_supply()
}

/// The original type of the package witness that issued the admission.
public fun admission_package_witness(self: &VenueAdmission): TypeName {
    self.package_witness
}

/// The original type of the admitted venue witness.
public fun admission_venue(self: &VenueAdmission): TypeName {
    self.venue
}

// === Imports ===

public use fun admission_package_witness as VenueAdmission.package_witness;
public use fun admission_venue as VenueAdmission.venue;

use std::type_name::{Self, TypeName};

use sui::coin::TreasuryCap;
