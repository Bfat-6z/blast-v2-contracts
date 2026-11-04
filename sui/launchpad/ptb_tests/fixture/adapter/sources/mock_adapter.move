// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Publishable sealed venue for the programmable-transaction migration harness.
///
/// `prepare` and `migrate` are the only entry points the harness calls. The venue owns the private
/// witness: `prepare` issues the ticket a SUI-quoted launch redeems, and `migrate` redeems the
/// launch's hand-off into a mock vault and can fail after the launch has migrated.
module ptb_adapter::mock_adapter;

// === Public Types ===

/// Venue identity only this module can construct.
public struct Venue() has drop;

/// Permanent custody of the handoff.
public struct MockVault<phantom Meme> has key {
    id: UID,
    meme: Balance<Meme>,
    quote: Balance<SUI>,
}

// === Public Functions ===

/// Issues the ticket a SUI-quoted launch of `Meme` redeems, as a venue's `prepare` does. The
/// caller passes it to `launch::new`, sets the launch settings, and finalizes it in the same
/// transaction.
public fun prepare<Meme>(): VenueTicket<Meme, SUI> {
    migration::issue_ticket(Venue())
}

/// Redeems the launch's hand-off in one call and returns nothing. `fail` aborts after the launch
/// migrated.
public fun migrate<Meme>(
    launch: &mut Launch<Meme, SUI>,
    version: &PackageVersion,
    config: &LaunchConfig,
    currency: &mut Currency<Meme>,
    fail: bool,
    ctx: &mut TxContext,
) {
    let (meme, quote, _) = launch.migrate(version, config, currency, ctx).redeem(Venue());
    transfer::share_object(MockVault { id: object::new(ctx), meme, quote });
    assert!(!fail, EAdapterFailure);
}

// === Errors ===

const EAdapterFailure: u64 = 0;

// === Imports ===

use blast_core::migration::{Self, VenueTicket};

use blast_fun::{blast_fun::PackageVersion, launch::Launch, launch_config::LaunchConfig};

use sui::{balance::Balance, coin_registry::Currency, sui::SUI};
