// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the treasury's abort location.
#[allow(lint(abort_without_constant))]
/// The one address every Blast fee is paid to, for every product and vault. A `TreasuryAdmin`
/// schedules a change behind the applied notice, a `CancelAdmin` cancels it, and anyone applies a
/// ready one.
module blast_core::blast_treasury;

// === Public Types ===

/// Shared singleton holding the protocol destination.
public struct Treasury has key {
    id: UID,
    destination: Delayed<DestinationKey, address>,
}

/// Keys the destination's delayed lifecycle.
public struct DestinationKey() has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(@blast_treasury, ctx));
}

// === Public Functions ===

/// Schedules a new nonzero destination and next notice, ready after the applied notice.
public fun schedule_destination(
    self: &mut Treasury,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
    delay_ms: u64,
    clock: &Clock,
) {
    assert!(destination != @0x0, blast_core::errors::invalid_treasury!());

    self.destination.schedule(destination, delay_ms, clock);
}

/// Applies the scheduled destination once ready.
public fun apply_destination(self: &mut Treasury, clock: &Clock) {
    self.destination.apply(clock);
}

/// Cancels the pending change, even a ready one.
public fun cancel_destination(self: &mut Treasury, _: &AdminWitness<CancelAdmin>) {
    self.destination.cancel();
}

/// The address Blast's fees are paid to now.
public fun destination(self: &Treasury): address {
    self.destination.value()
}

/// Whether every change waits a nonzero notice.
public fun is_guarded(self: &Treasury): bool {
    self.destination.is_guarded()
}

// === Private Functions ===

fun new(destination: address, ctx: &mut TxContext): Treasury {
    assert!(destination != @0x0, blast_core::errors::invalid_treasury!());
    let id = object::new(ctx);
    let destination = delayed::new(
        DestinationKey(),
        &id,
        destination,
        constants::initial_treasury_delay_ms!(),
    );

    Treasury { id, destination }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(destination: address, ctx: &mut TxContext): Treasury {
    new(destination, ctx)
}

#[test_only]
public fun share_for_testing(self: Treasury) {
    transfer::share_object(self);
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, delayed::{Self, Delayed}};

use blast_core::{blast_domain::{CancelAdmin, TreasuryAdmin}, constants};

use sui::clock::Clock;
