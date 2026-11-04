// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the split's abort location.
#[allow(lint(abort_without_constant))]
/// How every LP-fee collection is divided after Blast's share: typed routes to addresses, the
/// vault's owner, auto-LP, holder rewards, and burn, summing to exactly 10,000 basis points.
module blast_core::fee_split;

// === Public Types ===

/// Where one route's part of each collection goes. The vault decides what each special kind does
/// with it: the owner claims its part, auto-LP adds liquidity, holder rewards fund rounds, and burn
/// burns Meme and buys Meme back with Quote to burn.
public enum Destination has copy, drop, store {
    Address(address),
    Owner,
    AutoLp,
    HolderRewards,
    Burn,
}

/// One route's destination and positive share.
public struct Route has copy, drop, store {
    destination: Destination,
    bps: Bps,
}

/// Validated routes: at most 20 (16 addresses and the four special kinds), each positive, no
/// address twice, at most one of each special kind, summing to exactly 10,000. Only `new` builds
/// one, so every split a vault holds assigns each collection in full.
public struct FeeSplit has copy, drop, store {
    routes: vector<Route>,
}

// === Public Functions ===

public fun to_address(destination: address): Destination {
    assert!(destination != @0x0, blast_core::errors::invalid_route!());

    Destination::Address(destination)
}

public fun to_owner(): Destination { Destination::Owner }

public fun to_auto_lp(): Destination { Destination::AutoLp }

public fun to_holder_rewards(): Destination { Destination::HolderRewards }

public fun to_burn(): Destination { Destination::Burn }

public fun route(destination: Destination, bps: Bps): Route {
    assert!(bps.value() > 0, blast_core::errors::invalid_route!());

    Route { destination, bps }
}

public fun new(routes: vector<Route>): FeeSplit {
    assert!(
        routes.length() <= constants::max_routes!()
            && routes.all!(|route| {
                routes.count!(|other| other.destination == route.destination) == 1
            }),
        blast_core::errors::invalid_fee_split!(),
    );
    assert!(
        bps::total(&routes.map_ref!(|route| route.bps)) == constants::basis_points_denominator!(),
        blast_core::errors::invalid_fee_split!(),
    );

    FeeSplit { routes }
}

/// Splits `total` across the routes exactly, in route order.
public fun apportion(self: &FeeSplit, total: u64): vector<u64> {
    bps::apportion(self.routes.map_ref!(|route| route.bps), total, option::none())
}

public fun routes(self: &FeeSplit): &vector<Route> { &self.routes }

public fun destination(self: &Route): Destination { self.destination }

public fun bps(self: &Route): Bps { self.bps }

/// The route's address, or none for a special kind.
public fun address_of(self: &Destination): Option<address> {
    match (self) {
        Destination::Address(destination) => option::some(*destination),
        _ => option::none(),
    }
}

public fun is_owner(self: &Destination): bool { *self == Destination::Owner }

public fun is_auto_lp(self: &Destination): bool { *self == Destination::AutoLp }

public fun is_holder_rewards(self: &Destination): bool { *self == Destination::HolderRewards }

public fun is_burn(self: &Destination): bool { *self == Destination::Burn }

// === Imports ===

use blast_core::{bps::{Self, Bps}, constants};
