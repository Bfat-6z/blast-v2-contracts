// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's share of the LP fees every migrated position collects.
///
/// Bonding-curve trades read the launchpad's `RuntimeConfig`; migrated positions read this
/// object instead, so the two policies change independently. Every collection reads it live:
/// the coin's own pair when an administrator set one, otherwise the default pair, and the
/// current payout destination.
module blast_fun_migrators::lp_fee_policy;

// === Constants ===

/// The notice every policy change waits from publication: the genesis destination and default
/// shares are compiled, so no setup needs a zero notice.
const INITIAL_POLICY_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Public Types ===

/// Shared singleton holding independent Meme/Quote Blast shares and the address every vault pays
/// the protocol share to. Per-coin overrides use original Meme type identity, require no
/// iteration or cardinality cap, and share one notice of their own.
public struct LpFeePolicy has key {
    id: UID,
    destination: Delayed<ProtocolDestinationKey, address>,
    defaults: Delayed<DefaultSharesKey, SharePair>,
    coins: DelayedMap<CoinSharesKey, TypeName, SharePair>,
}

/// Keys the protocol destination's delayed lifecycle.
public struct ProtocolDestinationKey() has copy, drop, store;

/// Keys the default shares' delayed lifecycle.
public struct DefaultSharesKey() has copy, drop, store;

/// Keys the per-coin share overrides' delayed lifecycle; each event names its coin.
public struct CoinSharesKey() has copy, drop, store;

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
        INITIAL_POLICY_DELAY_MS,
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

    assert!(destination != @0x0, EInvalidProtocolDestination);

    self.destination.schedule(destination, delay_ms, clock);
}

/// Applies the scheduled protocol destination permissionlessly once ready.
public fun apply_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock,
) {
    migrators_version.assert_current();

    self.destination.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    self.destination.cancel();
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

    self.defaults.schedule(SharePair { meme_bps, quote_bps }, delay_ms, clock);
}

/// Applies the scheduled default shares permissionlessly once ready.
public fun apply_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock,
) {
    migrators_version.assert_current();

    self.defaults.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    migrators_version.assert_current();

    self.defaults.cancel();
}

/// Proposes both shares for this original Meme type, ready after the coin overrides' notice.
/// Setting the current defaults is a real transition because later default changes skip the coin.
public fun schedule_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    clock: &Clock
) {
    migrators_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();
    self.coins.schedule(meme, option::some(SharePair { meme_bps, quote_bps }), clock);
}

/// Proposes returning this coin to the defaults. Removing an override may increase fees
/// through the defaults, so it also waits the coin overrides' notice.
public fun schedule_clear_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    clock: &Clock
) {
    migrators_version.assert_current();

    self.coins.schedule(type_name::with_original_ids<Meme>(), option::none(), clock);
}

/// Applies either the approved override or the approved return to live defaults.
public fun apply_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock
) {
    migrators_version.assert_current();

    self.coins.apply(type_name::with_original_ids<Meme>(), clock);
}

/// Cancels either pending operation without changing the live override.
public fun cancel_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>
) {
    migrators_version.assert_current();

    self.coins.cancel(type_name::with_original_ids<Meme>());
}

/// Proposes the notice every later coin override waits, after the applied one.
public fun schedule_coin_shares_delay(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<FeeAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    migrators_version.assert_current();

    self.coins.schedule_delay(delay_ms, clock);
}

/// Applies a ready coin-override notice; pending overrides keep their deadlines.
public fun apply_coin_shares_delay(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    clock: &Clock
) {
    migrators_version.assert_current();

    self.coins.apply_delay(clock);
}

/// Cancels a pending coin-override notice change.
public fun cancel_coin_shares_delay(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<CancelAdmin>
) {
    migrators_version.assert_current();

    self.coins.cancel_delay();
}

// === Package Functions ===

/// Returns the address paid the protocol share of every collection.
public(package) fun protocol_destination(self: &LpFeePolicy): address {
    self.destination.value()
}

/// Returns the Meme and Quote shares a collection for `Meme` pays Blast now.
public(package) fun shares<Meme>(self: &LpFeePolicy): (Bps, Bps) {
    let live_pair = self.coins
        .value(&type_name::with_original_ids<Meme>())
        .get_with_default(self.defaults.value());

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
    assert!(@blast_lp_fee_destination != @0x0, EInvalidProtocolDestination);
    let id = object::new(ctx);

    LpFeePolicy {
        destination: delayed::new(ProtocolDestinationKey(), &id, destination, delay_ms),
        defaults: delayed::new(DefaultSharesKey(), &id, defaults, delay_ms),
        coins: delayed_map::new(CoinSharesKey(), &id, delay_ms, ctx),
        id,
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
    self.schedule_clear_coin_shares<Meme>(migrators_version, admin, &clock);
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
/// Runs publication initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Shares the publication policy at zero notice, for tests of delayed-change semantics.
public fun share_zero_notice_for_testing(ctx: &mut TxContext) {
    transfer::share_object(new(
        @blast_lp_fee_destination,
        SharePair { meme_bps: bps::new(1_500), quote_bps: bps::new(1_500) },
        0,
        ctx,
    ));
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
/// Returns the per-coin overrides, their pending changes and their notice.
public fun coin_shares_for_testing(self: &LpFeePolicy): &DelayedMap<CoinSharesKey, TypeName, SharePair> {
    &self.coins
}

#[test_only]
/// Returns the Meme and Quote shares of every coin without its own pair.
public fun default_shares_for_testing(self: &LpFeePolicy): (Bps, Bps) {
    (self.defaults.value().meme_bps, self.defaults.value().quote_bps)
}

// === Errors ===

#[error(code = 0)]
const EInvalidProtocolDestination: vector<u8> = b"Protocol destination must be a nonzero address.";

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed},
    delayed_map::{Self, DelayedMap},
    blast_acl::AdminWitness,
};

use sui::clock::Clock;

use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps::{Self, Bps}};

use blast_fun_migrators::{blast_fun_migrators::PackageVersion as MigratorsVersion};

use std::type_name::{Self, TypeName};
