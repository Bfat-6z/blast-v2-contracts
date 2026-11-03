// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

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

    assert!(destination != @0x0, EInvalidDestination);

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

/// Blast's rates, within the bounds every presale can apportion: a raise share below 10,000 BPS
/// and a token share of at most 9,998.
public(package) fun protocol_fees(
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    assert!(
        raise_bps.value() < bps::denominator() && token_bps.value() <= MAX_TOKEN_BPS,
        EInvalidFees,
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

/// Returns these rates with both LP-fee rates replaced.
public(package) fun with_lp_fees(
    mut self: ProtocolFees,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    self.lp_fee_meme_bps = lp_fee_meme_bps;
    self.lp_fee_quote_bps = lp_fee_quote_bps;
    self
}

// === Private Functions ===

fun new(
    destination: address,
    fees: ProtocolFees,
    delay_ms: u64,
    ctx: &mut TxContext,
): FeePolicy {
    assert!(@blast_treasury != @0x0, EInvalidDestination);
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
    ProtocolFees {
        raise_bps: bps::new(raise_bps),
        token_bps: bps::new(token_bps),
        lp_fee_meme_bps: bps::new(lp_fee_meme_bps),
        lp_fee_quote_bps: bps::new(lp_fee_quote_bps),
    }
}

#[test_only]
public fun destroy_for_testing(self: FeePolicy) {
    let FeePolicy { id, destination, fees } = self;
    std::unit_test::destroy(destination);
    std::unit_test::destroy(fees);
    id.delete();
}

// === Constants ===

/// The sale and LP allocations each keep at least one BPS of the supply.
const MAX_TOKEN_BPS: u64 = 9_998;

// === Errors ===

#[error(code = 0)]
const EInvalidFees: vector<u8> = b"Blast's raise share must be below 10,000 BPS and its token share at most 9,998.";

#[error(code = 1)]
const EInvalidDestination: vector<u8> = b"The protocol destination must be a nonzero address.";

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed},
    blast_acl::AdminWitness,
};

use sui::clock::Clock;

use blast_presale::{
    blast_presale_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin},
    blast_presale_package::{PackageVersion},
    bps::{Self, Bps}
};
