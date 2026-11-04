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

/// Validated routes: at most 20, each positive, no address twice, at most one of each special
/// kind, summing to exactly 10,000. Only `new` builds one, so every split a vault holds assigns
/// each collection in full.
public struct FeeSplit has copy, drop, store {
    routes: vector<Route>,
}

// === Public Functions ===

/// A route to `destination`; aborts for the zero address.
public fun address_destination(destination: address): Destination {
    assert!(destination != @0x0, blast_core::errors::invalid_route!());

    Destination::Address(destination)
}

/// A route to the vault's owner, who claims its part with an owner proof.
public fun owner_destination(): Destination { Destination::Owner }

/// A route the vault adds back into its position as liquidity.
public fun auto_lp_destination(): Destination { Destination::AutoLp }

/// A route that funds the vault's holder-reward rounds.
public fun holder_rewards_destination(): Destination { Destination::HolderRewards }

/// A route whose Meme is burned and whose Quote buys Meme back to burn.
public fun burn_destination(): Destination { Destination::Burn }

/// A route of `bps` to `destination`; aborts for a zero share.
public fun route(destination: Destination, bps: Bps): Route {
    assert!(bps.value() > 0, blast_core::errors::invalid_route!());

    Route { destination, bps }
}

/// A fee split of `routes`; aborts unless they are at most 20, distinct, and sum to 10,000.
public fun new(routes: vector<Route>): FeeSplit {
    assert!(
        routes.length() <= constants::max_routes!()
            && routes.all!(|route| {
                routes.count!(|other| other.destination == route.destination) == 1
            }),
        blast_core::errors::invalid_fee_split!(),
    );
    assert!(
        bps::sum(routes.map_ref!(|route| route.bps)) == constants::basis_points_denominator!(),
        blast_core::errors::invalid_fee_split!(),
    );

    FeeSplit { routes }
}

/// Splits `total` across the routes exactly, in route order.
public fun apportion(self: &FeeSplit, total: u64): vector<u64> {
    bps::apportion(self.routes.map_ref!(|route| route.bps), total, option::none())
}

/// The routes, in the order `apportion` pays them.
public fun routes(self: &FeeSplit): &vector<Route> { &self.routes }

/// Where the route pays.
public fun destination(self: &Route): Destination { self.destination }

/// The route's share.
public fun bps(self: &Route): Bps { self.bps }

/// The route's address, or none for a special kind.
public fun address_of(self: &Destination): Option<address> {
    match (self) {
        Destination::Address(destination) => option::some(*destination),
        _ => option::none(),
    }
}

/// Whether the destination is the vault's owner.
public fun is_owner(self: &Destination): bool { *self == Destination::Owner }

/// Whether the destination is auto-LP.
public fun is_auto_lp(self: &Destination): bool { *self == Destination::AutoLp }

/// Whether the destination is holder rewards.
public fun is_holder_rewards(self: &Destination): bool { *self == Destination::HolderRewards }

/// Whether the destination is burn.
public fun is_burn(self: &Destination): bool { *self == Destination::Burn }

// === Imports ===

use blast_core::{bps::{Self, Bps}, constants};
