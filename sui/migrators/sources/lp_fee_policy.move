// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's share of the LP fees every migrated position collects.
///
/// Bonding-curve trades read the launchpad's `RuntimeConfig`; migrated positions read this
/// object instead, so the two policies change independently. Every collection reads it live:
/// the coin's own pair when an administrator set one, otherwise the default pair, and the
/// current payout destination.
module blast_fun_migrators::lp_fee_policy;

// === Public Types ===

/// Shared singleton holding independent Meme/Quote Blast shares and the address every vault pays
/// the protocol share to. Per-coin entries use original Meme type identity and require no
/// iteration or cardinality cap.
public struct LpFeePolicy has key {
    id: UID,
    destination: Delayed<address>,
    defaults: Delayed<SharePair>,
    coins: Table<TypeName, Delayed<Option<SharePair>>>,
}

/// Atomic pair of validated shares; a per-coin entry always replaces both assets together.
public struct SharePair has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(
        @blast_lp_fee_destination,
        SharePair { meme_bps: bps::new(1_500), quote_bps: bps::new(1_500) },
        0,
        ctx,
    ));
}

// === Public Functions ===

/// Redirects every later protocol share payout.
/// Schedules protocol destination after the full administrative delay.
public fun schedule_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
    delay_ms: u64,
    clock: &Clock,
) {
    migrators_version.assert_current();

    assert!(destination != @0x0, EProtocolDestinationUnchanged);

    let value = destination;
    assert!(
        value != self.destination.value() || delay_ms != self.destination.delay_ms(),
        EProtocolDestinationUnchanged
    );

    let ready_at_ms = self.destination.schedule(value, delay_ms, clock);

    blast_events::protocol_destination_scheduled(destination, ready_at_ms, delay_ms);
}

/// Applies the scheduled protocol destination permissionlessly once ready.
public fun apply_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock,
) {
    migrators_version.assert_current();

    let old_destination = self.destination.value();
    let value = self.destination.apply(clock);
    let destination = value;

    blast_events::lp_fee_destination_changed(old_destination, destination);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    let value = self.destination.cancel();
    let destination = value;

    blast_events::protocol_destination_cancelled(destination);
}

/// Changes both default shares for every coin without its own pair, from its next collection.
/// Schedules default shares after the full administrative delay.
public fun schedule_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    migrators_version.assert_current();

    let value = SharePair { meme_bps, quote_bps };
    assert!(
        value != self.defaults.value() || delay_ms != self.defaults.delay_ms(),
        EProtocolFeeSharesUnchanged
    );

    let ready_at_ms = self.defaults.schedule(value, delay_ms, clock);

    blast_events::default_shares_scheduled(
        meme_bps.value(),
        quote_bps.value(),
        ready_at_ms,
        delay_ms
    );
}

/// Applies the scheduled default shares permissionlessly once ready.
public fun apply_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock,
) {
    migrators_version.assert_current();

    let old_defaults = self.defaults.value();
    let value = self.defaults.apply(clock);
    let meme_bps = value.meme_bps;
    let quote_bps = value.quote_bps;

    blast_events::lp_fee_policy_changed(
        option::none(),
        option::some(old_defaults.meme_bps.value()),
        option::some(old_defaults.quote_bps.value()),
        option::some(meme_bps.value()),
        option::some(quote_bps.value())
    );
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    let value = self.defaults.cancel();
    let meme_bps = value.meme_bps;
    let quote_bps = value.quote_bps;

    blast_events::default_shares_cancelled(meme_bps.value(), quote_bps.value());
}

/// Schedules both shares for this original Meme type after the administrative delay.
/// Setting the current defaults is a real transition because later default changes skip the coin.
public fun schedule_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock
) {
    migrators_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();
    let proposed = option::some(SharePair { meme_bps, quote_bps });
    if (!self.coins.contains(meme))
        self.coins.add(meme, delayed::new(option::none(), self.defaults.delay_ms()));
    assert!(
        self.coins[meme].value() != proposed || delay_ms != self.coins[meme].delay_ms(),
        EProtocolFeeSharesUnchanged
    );

    let ready_at_ms = self.coins[meme].schedule(proposed, delay_ms, clock);

    blast_events::coin_shares_scheduled(
        meme,
        option::some(meme_bps.value()),
        option::some(quote_bps.value()),
        ready_at_ms,
        delay_ms
    );
}

/// Removing an override may increase fees through defaults, so it also requires notice.
public fun schedule_clear_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    migrators_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();
    assert!(
        self.coins[meme].value().is_some() || delay_ms != self.coins[meme].delay_ms(),
        EProtocolFeeSharesUnchanged
    );

    let ready_at_ms = self.coins[meme].schedule(option::none(), delay_ms, clock);

    blast_events::coin_shares_scheduled(
        meme,
        option::none(),
        option::none(),
        ready_at_ms,
        delay_ms
    );
}

/// Applies either the approved override or the approved return to live defaults.
public fun apply_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock
) {
    migrators_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();
    let previous = self.coins[meme].value();
    let applied = self.coins[meme].apply(clock);

    blast_events::lp_fee_policy_changed(
        option::some(meme),
        previous.map!(|p| p.meme_bps.value()),
        previous.map!(|p| p.quote_bps.value()),
        applied.map!(|p| p.meme_bps.value()),
        applied.map!(|p| p.quote_bps.value())
    );
}

/// Cancels either pending operation without changing the live override.
public fun cancel_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>
) {
    migrators_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();
    let cancelled = self.coins[meme].cancel();

    blast_events::coin_shares_cancelled(
        meme,
        cancelled.map!(|p| p.meme_bps.value()),
        cancelled.map!(|p| p.quote_bps.value())
    );
}

// === Package Functions ===

/// Returns the address paid the protocol share of every collection.
public(package) fun protocol_destination(self: &LpFeePolicy): address {
    self.destination.value()
}

/// Returns the Meme and Quote shares a collection for `Meme` pays Blast now.
public(package) fun shares<Meme>(self: &LpFeePolicy): (Bps, Bps) {
    let meme = type_name::with_original_ids<Meme>();
    let override = if (self.coins.contains(meme)) self.coins[meme].value() else option::none();
    let live_pair = override.get_with_default(self.defaults.value());

    (live_pair.meme_bps, live_pair.quote_bps)
}

// === Private Functions ===

/// Initializes the explicit genesis destination; an unset destination prevents publication.
fun new(
    destination: address,
    defaults: SharePair,
    delay_ms: u64,
    ctx: &mut TxContext,
): LpFeePolicy {
    assert!(@blast_lp_fee_destination != @0x0, EProtocolDestinationUnchanged);
    LpFeePolicy {
        id: object::new(ctx),
        destination: delayed::new(destination, delay_ms),
        defaults: delayed::new(defaults, delay_ms),
        coins: table::new(ctx),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun set_coin_shares_for_testing<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    admin: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_coin_shares<Meme>(
        migrators_version,
        admin,
        meme_bps,
        quote_bps,
        172_800_000,
        &clock
    );
    clock.set_for_testing(172_800_000);
    self.apply_coin_shares<Meme>(migrators_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun clear_coin_shares_for_testing<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    admin: &AdminWitness<FeeAdmin>,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_clear_coin_shares<Meme>(migrators_version, admin, 172_800_000, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_coin_shares<Meme>(migrators_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_default_shares_for_testing(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    admin: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.defaults.delay_ms();
    self.schedule_default_shares(migrators_version, admin, meme_bps, quote_bps, delay_ms, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_default_shares(migrators_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_destination_for_testing(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    admin: &AdminWitness<TreasuryAdmin>,
    destination: address,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.destination.delay_ms();
    self.schedule_protocol_destination(migrators_version, admin, destination, delay_ms, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_protocol_destination(migrators_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Runs eventless publication initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Explicit zero-share fixture with the existing administrative notice.
public fun new_zero_fees_for_testing(ctx: &mut TxContext): LpFeePolicy {
    new(
        ctx.sender(),
        SharePair { meme_bps: bps::new(0), quote_bps: bps::new(0) },
        172_800_000,
        ctx,
    )
}

#[test_only]
/// Shares a zero-share genesis fixture without changing notice semantics.
public fun init_zero_fees_for_testing(ctx: &mut TxContext) {
    transfer::share_object(new(
        @blast_lp_fee_destination,
        SharePair { meme_bps: bps::new(0), quote_bps: bps::new(0) },
        0,
        ctx,
    ));
}

#[test_only]
/// Returns the number of stored per-coin pairs for type-key and cleanup tests.
public fun coin_count_for_testing(self: &LpFeePolicy): u64 {
    self.coins.length()
}

#[test_only]
/// Returns the Meme and Quote shares of every coin without its own pair.
public fun default_shares_for_testing(self: &LpFeePolicy): (Bps, Bps) {
    (self.defaults.value().meme_bps, self.defaults.value().quote_bps)
}

// === Errors ===

#[error(code = 0)]
const EProtocolDestinationUnchanged: vector<u8> = b"Protocol destination must be a new nonzero address.";

#[error(code = 1)]
const EProtocolFeeSharesUnchanged: vector<u8> = b"LP-fee share update must change the stored pair.";

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed},
    blast_acl::AdminWitness,
};

use sui::{
    clock::Clock,
    table::{Self, Table},
};

use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps::{Self, Bps}};

use blast_fun_migrators::{blast_events, blast_fun_migrators::PackageVersion as MigratorsVersion};

use std::type_name::{Self, TypeName};
