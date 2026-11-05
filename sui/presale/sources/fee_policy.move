// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fees on presales: a share of every successful raise, of every token supply, and of
/// every collected LP fee.
///
/// Each presale snapshots the rates when it is created. Until the sale's window starts, the
/// `FeeAdmin` may change that sale's rates, so its economics are fixed before commitments open;
/// the LP-fee rates then pass to the sale's vault in its migration terms, which changes them per
/// vault after delay. Blast's fees are paid to the one `blast_core::blast_treasury::Treasury`.
module blast_presale::fee_policy;

// === Public Types ===

/// Shared singleton holding the rates new presales snapshot.
public struct FeePolicy has key {
    id: UID,
    fees: Delayed<FeesKey, ProtocolFees>,
}

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
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<FeeAdmin>,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let value = protocol_fees(raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps);

    self.fees.schedule(value, delay_ms, clock);
}

/// Applies the scheduled fees permissionlessly once ready.
public fun apply_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.fees.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.fees.cancel();
}

// === Package Functions ===

/// Blast's rates, within the compiled maximums: at most 1,000 BPS of the raise and of the
/// tokens, and at most `blast_core::constants::max_lp_fee_bps` of each LP fee.
public(package) fun protocol_fees(
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    assert!(
        raise_bps.value() <= constants::max_raise_bps!()
            && token_bps.value() <= constants::max_token_bps!()
            && lp_fee_meme_bps.value() <= blast_core::constants::max_lp_fee_bps!()
            && lp_fee_quote_bps.value() <= blast_core::constants::max_lp_fee_bps!(),
        blast_presale::errors::invalid_fees!(),
    );

    ProtocolFees { raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps }
}

/// True when the rates' delay is guarded (see `creation_policy::unpause`).
public(package) fun is_guarded(self: &FeePolicy): bool {
    self.fees.is_guarded()
}

public(package) fun fees(self: &FeePolicy): ProtocolFees {
    self.fees.value()
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

// === Private Functions ===

fun new(fees: ProtocolFees, delay_ms: u64, ctx: &mut TxContext): FeePolicy {
    let id = object::new(ctx);

    FeePolicy { fees: delayed::new(FeesKey(), &id, fees, delay_ms), id }
}

// === Test-Only Functions ===

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_fees_for_testing(
    self: &mut FeePolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
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
        &clock,
    );
    clock.set_for_testing(delay_ms);
    self.apply_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
/// Explicit zero-fee fixture with the 48-hour administrative delay.
public fun new_zero_fees_for_testing(ctx: &mut TxContext): FeePolicy {
    new(
        protocol_fees(bps::new(0), bps::new(0), bps::new(0), bps::new(0)),
        blast_admin::package_admin::initial_upgrade_delay_ms_for_testing(),
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
    let FeePolicy { id, fees } = self;
    std::unit_test::destroy(fees);
    id.delete();
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, delayed::{Self, Delayed}, package_version::PackageVersion};

use blast_core::{bps::{Self, Bps}, blast_domain::{CancelAdmin, FeeAdmin}};

use blast_presale::{blast_presale_package::BLAST_PRESALE_PACKAGE, constants};

use sui::clock::Clock;
