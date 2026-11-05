// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the treasury's abort location.
#[allow(lint(abort_without_constant))]
/// The one address every Blast fee is paid to, for every product and vault. A `TreasuryAdmin`
/// schedules a change behind the applied delay, a `CancelAdmin` cancels it, and anyone applies a
/// ready one.
module blast_core::blast_treasury;

// === Public Types ===

/// Shared singleton holding the protocol destination. It has no destroy: every ledger pays
/// through it, so deleting it would strand Blast's held fees in every launch, presale, and vault.
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

/// Schedules a new nonzero destination and next delay, ready after the applied delay.
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

/// The delay the next change waits, in milliseconds.
public fun delay_ms(self: &Treasury): u64 {
    self.destination.delay_ms()
}

/// The scheduled destination with its next delay and ready time, if any.
public fun pending_destination(self: &Treasury): Option<Proposal<address>> {
    self.destination.pending()
}

/// Whether `apply_destination` would succeed now: a destination is scheduled, its ready time has
/// passed, and its next delay still fits in a Unix millisecond timestamp.
public fun is_destination_ready(self: &Treasury, clock: &Clock): bool {
    self.destination.is_ready(clock)
}

/// Whether every change waits a nonzero delay.
public fun is_guarded(self: &Treasury): bool {
    self.destination.is_guarded()
}

// === Private Functions ===

fun new(destination: address, ctx: &mut TxContext): Treasury {
    assert!(destination != @0x0, blast_core::errors::invalid_treasury!());
    let id = object::new(ctx);
    let destination_setting = delayed::new(
        DestinationKey(),
        &id,
        destination,
        constants::initial_treasury_delay_ms!(),
    );

    Treasury { id, destination: destination_setting }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(destination: address, ctx: &mut TxContext): Treasury {
    new(destination, ctx)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, delayed::{Self, Delayed, Proposal}};

use blast_core::{blast_domain::{CancelAdmin, TreasuryAdmin}, constants};

use sui::clock::Clock;
