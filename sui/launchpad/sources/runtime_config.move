// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Settings every curve trade, creator claim, and protocol fee claim reads live.
module blast_fun::runtime_config;

// === Public Types ===

/// The backend key that signs account claims (empty when none may), Blast's share of every
/// curve trade fee, and the treasury every launch pays Blast's fees to.
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: vector<u8>,
    protocol_fee_share_bps: Delayed<Bps>,
    treasury: Delayed<address>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Immediately assigns the backend claim signer under the live, revocable role.
public fun set_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ClaimSignerAdmin>,
    signer_public_key: vector<u8>
) {
    package_version.assert_current();

    assert!(
        signer_public_key.length() == constants::ed25519_public_key_length!(),
        blast_fun::errors::invalid_creator_claim_public_key!()
    );
    assert!(
        signer_public_key != self.creator_claim_signer_public_key,
        blast_fun::errors::unchanged!()
    );
    self.creator_claim_signer_public_key = signer_public_key;

    events::creator_claim_signer_set(signer_public_key);
}

/// Schedules protocol fee share after the full administrative delay.
public fun schedule_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    protocol_fee_share_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    let value = protocol_fee_share_bps;
    assert!(
        value != self.protocol_fee_share_bps.value() || delay_ms != self.protocol_fee_share_bps.delay_ms(),
        blast_fun::errors::unchanged!()
    );

    let ready_at_ms = self.protocol_fee_share_bps.schedule(value, delay_ms, clock);

    events::protocol_fee_share_scheduled(protocol_fee_share_bps.value(), ready_at_ms, delay_ms);
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

    events::protocol_fee_share_cancelled(protocol_fee_share_bps.value());
}

/// Redirects every later protocol fee claim to `treasury`.
/// Schedules treasury after the full administrative delay.
public fun schedule_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(treasury != @0x0, blast_fun::errors::invalid_destination!());

    let value = treasury;
    assert!(
        value != self.treasury.value() || delay_ms != self.treasury.delay_ms(),
        blast_fun::errors::unchanged!()
    );

    let ready_at_ms = self.treasury.schedule(value, delay_ms, clock);

    events::treasury_scheduled(treasury, ready_at_ms, delay_ms);
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

    events::treasury_cancelled(treasury);
}

/// Revokes the backend claim signer immediately.
public fun revoke_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ClaimSignerAdmin>,
) {
    package_version.assert_current();

    assert!(!self.creator_claim_signer_public_key.is_empty(), blast_fun::errors::unchanged!());
    self.creator_claim_signer_public_key = vector[];

    events::creator_claim_signer_set(vector[]);
}

// === Package Functions ===

public(package) fun creator_claim_signer(self: &RuntimeConfig): &vector<u8> {
    &self.creator_claim_signer_public_key
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
        creator_claim_signer_public_key: vector[],
        protocol_fee_share_bps: delayed::new(bps::new(0), 0),
        treasury: delayed::new(@blast_treasury, 0),
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
    let delay_ms = self.treasury.delay_ms();
    self.schedule_treasury(package_version, admin, treasury, delay_ms, &clock);
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
    let delay_ms = self.protocol_fee_share_bps.delay_ms();
    self.schedule_protocol_fee_share(
        package_version,
        admin,
        protocol_fee_share_bps,
        delay_ms,
        &clock
    );
    clock.set_for_testing(172_800_000);
    self.apply_protocol_fee_share(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_disabled_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new_for_testing(vector[], ctx)
}

#[test_only]
public fun new_for_testing(signer_public_key: vector<u8>, ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: signer_public_key,
        protocol_fee_share_bps: delayed::new(bps::new(0), 172_800_000),
        treasury: delayed::new(ctx.sender(), 172_800_000),
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
    blast_fun::{PackageVersion},
};
