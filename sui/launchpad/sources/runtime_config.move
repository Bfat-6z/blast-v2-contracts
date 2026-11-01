// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Settings every curve trade, creator claim, and protocol fee claim reads live.
module blast_fun::runtime_config;

// === Public Types ===

/// Proposed values and Unix millisecond execution threshold.
public struct TreasuryScheduled has copy, drop { treasury: address, ready_at_ms: u64 }
/// Values removed from the pending schedule.
public struct TreasuryCancelled has copy, drop { treasury: address }

/// Proposed values and Unix millisecond execution threshold.
public struct ProtocolFeeShareScheduled has copy, drop { protocol_fee_share_bps: u64, ready_at_ms: u64 }
/// Values removed from the pending schedule.
public struct ProtocolFeeShareCancelled has copy, drop { protocol_fee_share_bps: u64 }

/// Proposed values and Unix millisecond execution threshold.
public struct CreatorClaimSignerScheduled has copy, drop { signer_public_key: vector<u8>, ready_at_ms: u64 }
/// Values removed from the pending schedule.
public struct CreatorClaimSignerCancelled has copy, drop { signer_public_key: vector<u8> }

/// The backend key that signs account claims (empty when none may), Blast's share of every
/// curve trade fee, and the treasury every launch pays Blast's fees to.
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: Delayed<vector<u8>>,
    protocol_fee_share_bps: Delayed<Bps>,
    treasury: Delayed<address>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Replaces the account-claim signer; an empty key revokes it.
/// Schedules creator claim signer after the full administrative delay.
public fun schedule_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ClaimSignerAdmin>,
    signer_public_key: vector<u8>,
    clock: &Clock,
) {
    package_version.assert_current();
    assert!(!signer_public_key.is_empty() && signer_public_key.length() == constants::ed25519_public_key_length!(), blast_fun::errors::invalid_creator_claim_public_key!());
    let value = signer_public_key;
    assert!(value != self.creator_claim_signer_public_key.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.creator_claim_signer_public_key.schedule(value, clock);
    blast_fun::blast_events::emit_event(CreatorClaimSignerScheduled { signer_public_key: signer_public_key, ready_at_ms });
}

/// Applies the scheduled creator claim signer permissionlessly once ready.
public fun apply_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.creator_claim_signer_public_key.apply(clock);
    let signer_public_key = value;
    events::creator_claim_signer_set(signer_public_key);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.creator_claim_signer_public_key.cancel();
    let signer_public_key = value;
    blast_fun::blast_events::emit_event(CreatorClaimSignerCancelled { signer_public_key: signer_public_key });
}

/// Schedules protocol fee share after the full administrative delay.
public fun schedule_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    protocol_fee_share_bps: Bps,
    clock: &Clock,
) {
    package_version.assert_current();

    let value = protocol_fee_share_bps;
    assert!(value != self.protocol_fee_share_bps.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.protocol_fee_share_bps.schedule(value, clock);
    blast_fun::blast_events::emit_event(ProtocolFeeShareScheduled { protocol_fee_share_bps: protocol_fee_share_bps.value(), ready_at_ms });
}

/// Applies the scheduled protocol fee share permissionlessly once ready.
public fun apply_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.protocol_fee_share_bps.apply(clock);
    let protocol_fee_share_bps = value;
    events::protocol_fee_share_changed(protocol_fee_share_bps.value());
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.protocol_fee_share_bps.cancel();
    let protocol_fee_share_bps = value;
    blast_fun::blast_events::emit_event(ProtocolFeeShareCancelled { protocol_fee_share_bps: protocol_fee_share_bps.value() });
}

/// Redirects every later protocol fee claim to `treasury`.
/// Schedules treasury after the full administrative delay.
public fun schedule_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    clock: &Clock,
) {
    package_version.assert_current();
    assert!(treasury != @0x0, blast_fun::errors::invalid_destination!());
    let value = treasury;
    assert!(value != self.treasury.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.treasury.schedule(value, clock);
    blast_fun::blast_events::emit_event(TreasuryScheduled { treasury: treasury, ready_at_ms });
}

/// Applies the scheduled treasury permissionlessly once ready.
public fun apply_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.treasury.apply(clock);
    let treasury = value;
    events::treasury_changed(treasury);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.treasury.cancel();
    let treasury = value;
    blast_fun::blast_events::emit_event(TreasuryCancelled { treasury: treasury });
}

/// Revokes the claim signer immediately and clears any scheduled replacement.
public fun revoke_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ClaimSignerAdmin>,
) {
    package_version.assert_current();
    assert!(!self.creator_claim_signer_public_key.value().is_empty() || self.creator_claim_signer_public_key.pending().is_some(), blast_fun::errors::unchanged!());
    if (self.creator_claim_signer_public_key.pending().is_some()) {
        let signer_public_key = self.creator_claim_signer_public_key.cancel();
        blast_fun::blast_events::emit_event(CreatorClaimSignerCancelled { signer_public_key });
    };
    self.creator_claim_signer_public_key.set_now(vector[]);
    events::creator_claim_signer_set(vector[]);
}

// === Package Functions ===

public(package) fun creator_claim_signer(self: &RuntimeConfig): &vector<u8> {
    self.creator_claim_signer_public_key.borrow()
}

public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps.value()
}

public(package) fun treasury(self: &RuntimeConfig): address {
    self.treasury.value()
}

// === Private Functions ===

/// Initializes the explicit genesis destination; an unset destination prevents publication.
fun new(ctx: &mut TxContext): RuntimeConfig {
    assert!(@blast_treasury != @0x0, blast_fun::errors::invalid_destination!());
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: delayed::new(vector[]),
        protocol_fee_share_bps: delayed::new(bps::new(0)),
        treasury: delayed::new(@blast_treasury),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_treasury_for_testing(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_treasury(package_version, admin, treasury, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_treasury(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_fee_share_for_testing(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<FeeAdmin>,
    protocol_fee_share_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_protocol_fee_share(package_version, admin, protocol_fee_share_bps, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_protocol_fee_share(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_creator_claim_signer_for_testing(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<ClaimSignerAdmin>,
    signer_public_key: vector<u8>,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    if (signer_public_key.is_empty()) {
        self.revoke_creator_claim_signer(package_version, admin);
        clock.destroy_for_testing();
        return
    };
    self.schedule_creator_claim_signer(package_version, admin, signer_public_key, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_creator_claim_signer(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_disabled_for_testing(ctx: &mut TxContext): RuntimeConfig {
    let mut config = new(ctx);
    config.treasury.set_now(ctx.sender());
    config
}

#[test_only]
public fun new_for_testing(signer_public_key: vector<u8>, ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: delayed::new(signer_public_key),
        protocol_fee_share_bps: delayed::new(bps::new(0)),
        treasury: delayed::new(ctx.sender()),
    }
}

// === Imports ===

use blast_admin::{
    delayed::{Self, Delayed},
    blast_acl::AdminWitness,
};

use sui::clock::Clock;

use blast_fun::{
    blast_fun_domain::{CancelAdmin, ClaimSignerAdmin, FeeAdmin, TreasuryAdmin},
    bps::{Self, Bps},
    constants,
    events,
    blast_fun::PackageVersion,
};
