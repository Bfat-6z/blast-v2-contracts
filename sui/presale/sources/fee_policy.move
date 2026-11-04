// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fees on presales: a share of every successful raise, of every token supply, and of
/// every collected LP fee.
///
/// Each presale snapshots the rates when it is created. Until the sale's window starts, the
/// `FeeAdmin` may change that sale's rates, so its economics are fixed before commitments open;
/// after migration it may change the sale's LP-fee rates on its vault. Every payout reads the
/// current destination.
module blast_presale::fee_policy;

// === Public Types ===

/// Shared singleton holding the rates new presales snapshot and the address paid Blast's fees.
public struct FeePolicy has key {
    id: UID,
    destination: Delayed<DestinationKey, address>,
    fees: Delayed<FeesKey, ProtocolFees>,
}

/// Keys the delayed lifecycle of the address paid Blast's fees.
public struct DestinationKey() has copy, drop, store;

/// Keys the delayed lifecycle of the rates new presales snapshot.
public struct FeesKey() has copy, drop, store;

/// Blast's rates, in BPS: of the accepted raise, of the token supply, and of each collected
/// LP-fee asset.
public struct ProtocolFees has copy, drop, store {
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(
        @blast_treasury,
        protocol_fees(bps::new(200), bps::new(100), bps::new(1_500), bps::new(1_500)),
        0,
        ctx,
    ));
}

// === Public Functions ===

/// Sets the rates presales created afterward snapshot; existing presales keep theirs.
/// Schedules fees after the full administrative delay.
public fun schedule_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    let value = protocol_fees(raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps);

    self.fees.schedule(value, delay_ms, clock);
}

/// Applies the scheduled fees permissionlessly once ready.
public fun apply_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.fees.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.fees.cancel();
}

/// Redirects every later protocol payout, including those of existing presales.
/// Schedules destination after the full administrative delay.
public fun schedule_destination(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(destination != @0x0, blast_presale::errors::invalid_destination!());

    self.destination.schedule(destination, delay_ms, clock);
}

/// Applies the scheduled destination permissionlessly once ready.
public fun apply_destination(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.destination.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_destination(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.destination.cancel();
}

// === Package Functions ===

/// Blast's rates, within the compiled maximums: at most 1,000 BPS of the raise and of the
/// tokens, and at most 3,000 BPS of each LP fee.
public(package) fun protocol_fees(
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    assert!(
        raise_bps.value() <= constants::max_raise_bps!()
            && token_bps.value() <= constants::max_token_bps!()
            && lp_fee_meme_bps.value() <= constants::max_lp_fee_bps!()
            && lp_fee_quote_bps.value() <= constants::max_lp_fee_bps!(),
        blast_presale::errors::invalid_fees!(),
    );

    ProtocolFees { raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps }
}

/// True when every fee policy notice is guarded (see `package_admin::unpause`).
public(package) fun is_guarded(self: &FeePolicy): bool {
    self.destination.is_guarded() && self.fees.is_guarded()
}

public(package) fun fees(self: &FeePolicy): ProtocolFees {
    self.fees.value()
}

public(package) fun destination(self: &FeePolicy): address {
    self.destination.value()
}

public(package) fun raise_bps(self: &ProtocolFees): Bps {
    self.raise_bps
}

public(package) fun token_bps(self: &ProtocolFees): Bps {
    self.token_bps
}

public(package) fun lp_fee_meme_bps(self: &ProtocolFees): Bps {
    self.lp_fee_meme_bps
}

public(package) fun lp_fee_quote_bps(self: &ProtocolFees): Bps {
    self.lp_fee_quote_bps
}

/// Returns these rates with both LP-fee rates replaced, under the same maximums.
public(package) fun with_lp_fees(
    self: ProtocolFees,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    protocol_fees(self.raise_bps, self.token_bps, lp_fee_meme_bps, lp_fee_quote_bps)
}

// === Private Functions ===

fun new(
    destination: address,
    fees: ProtocolFees,
    delay_ms: u64,
    ctx: &mut TxContext,
): FeePolicy {
    assert!(@blast_treasury != @0x0, blast_presale::errors::invalid_destination!());
    let id = object::new(ctx);

    FeePolicy {
        destination: delayed::new(DestinationKey(), &id, destination, delay_ms),
        fees: delayed::new(FeesKey(), &id, fees, delay_ms),
        id,
    }
}

// === Test-Only Functions ===

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_destination_for_testing(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    admin: &AdminWitness<TreasuryAdmin>,
    destination: address,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.destination.delay_ms();
    self.schedule_destination(package_version, admin, destination, delay_ms, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_destination(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_fees_for_testing(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    admin: &AdminWitness<FeeAdmin>,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.fees.delay_ms();
    self.schedule_fees(
        package_version,
        admin,
        raise_bps,
        token_bps,
        lp_fee_meme_bps,
        lp_fee_quote_bps,
        delay_ms,
        &clock
    );
    clock.set_for_testing(172_800_000);
    self.apply_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
/// Explicit zero-fee fixture with the existing administrative notice.
public fun new_zero_fees_for_testing(ctx: &mut TxContext): FeePolicy {
    new(
        ctx.sender(),
        protocol_fees(bps::new(0), bps::new(0), bps::new(0), bps::new(0)),
        172_800_000,
        ctx,
    )
}

#[test_only]
public fun protocol_fees_for_testing(
    raise_bps: u64,
    token_bps: u64,
    lp_fee_meme_bps: u64,
    lp_fee_quote_bps: u64,
): ProtocolFees {
    protocol_fees(
        bps::new(raise_bps),
        bps::new(token_bps),
        bps::new(lp_fee_meme_bps),
        bps::new(lp_fee_quote_bps),
    )
}

#[test_only]
public fun destroy_for_testing(self: FeePolicy) {
    let FeePolicy { id, destination, fees } = self;
    std::unit_test::destroy(destination);
    std::unit_test::destroy(fees);
    id.delete();
}

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed},
    blast_acl::AdminWitness,
};

use sui::clock::Clock;

use blast_presale::{
    blast_presale_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin},
    blast_presale_package::{PackageVersion},
    bps::{Self, Bps},
    constants
};
