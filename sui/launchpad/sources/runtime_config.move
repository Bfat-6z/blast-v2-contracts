// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Settings every curve trade and creator claim reads live.
module blast_fun::runtime_config;

// === Public Types ===

/// The backend keys that may sign account claims (none when empty) and Blast's share of every
/// curve trade fee. Blast's fees are paid to `blast_core::blast_treasury::Treasury`.
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signers: DelayedSet<ClaimSignerKey, vector<u8>>,
    protocol_fee_share_bps: Delayed<ProtocolFeeShareKey, Bps>,
}

/// Keys the protocol fee share's delayed lifecycle.
public struct ProtocolFeeShareKey() has copy, drop, store;

/// Keys the account-claim signer set's delayed lifecycle.
public struct ClaimSignerKey() has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Proposes admitting a backend key that may sign account claims, after the signer delay.
/// Every admitted key signs with full authority, so admission waits; removal does not.
public fun schedule_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<ClaimSignerAdmin>,
    signer_public_key: vector<u8>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(
        signer_public_key.length() == constants::ed25519_public_key_length!(),
        blast_fun::errors::invalid_creator_claim_public_key!()
    );
    // Rescheduling a pending key replaces its admission rather than adding one.
    let signers = &self.creator_claim_signers;
    let replaced = if (signers.admission_ready_at_ms(&signer_public_key).is_some()) 1 else 0;
    assert!(
        signers.members().length() + signers.pending_count() - replaced
            < constants::max_claim_signers!(),
        blast_fun::errors::too_many_claim_signers!()
    );

    self.creator_claim_signers.schedule_add(signer_public_key, clock);
}

/// Admits a ready signer key. Anyone may call.
public fun apply_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    signer_public_key: vector<u8>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.apply_add(signer_public_key, clock);
}

/// Discards a pending signer admission, even a ready one.
public fun cancel_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
    signer_public_key: vector<u8>,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.cancel_add(signer_public_key);
}

/// Proposes the delay later signer admissions wait, after the applied one.
public fun schedule_creator_claim_signer_delay(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<ClaimSignerAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.schedule_delay(delay_ms, clock);
}

/// Applies a ready signer delay; pending admissions keep their deadlines. Anyone may call.
public fun apply_creator_claim_signer_delay(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.apply_delay(clock);
}

/// Discards a pending signer delay change.
public fun cancel_creator_claim_signer_delay(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.cancel_delay();
}

/// Schedules protocol fee share, at most 7,000 bps, after the full administrative delay.
public fun schedule_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    protocol_fee_share_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self
        .protocol_fee_share_bps
        .schedule(checked_protocol_fee_share(protocol_fee_share_bps), delay_ms, clock);
}

/// Applies the scheduled protocol fee share permissionlessly once ready.
public fun apply_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.protocol_fee_share_bps.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.protocol_fee_share_bps.cancel();
}

/// Revokes a signer key at once, live or pending, so a leaked key stops signing immediately.
/// Attestations it already signed stop verifying too.
public fun revoke_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<ClaimSignerAdmin>,
    signer_public_key: vector<u8>,
) {
    package_version.assert_current(constants::version!());

    self.creator_claim_signers.remove(signer_public_key);
}

// === Package Functions ===

/// True when every runtime policy's delay is guarded (see `launch_config::unpause`).
public(package) fun is_guarded(self: &RuntimeConfig): bool {
    self.creator_claim_signers.is_guarded() && self.protocol_fee_share_bps.is_guarded()
}

/// The keys that may sign account claims now.
public(package) fun creator_claim_signers(self: &RuntimeConfig): vector<vector<u8>> {
    self.creator_claim_signers.members().into_keys()
}

public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps.value()
}

// === Private Functions ===

fun new(ctx: &mut TxContext): RuntimeConfig {
    let id = object::new(ctx);

    RuntimeConfig {
        creator_claim_signers: delayed_set::new(ClaimSignerKey(), &id, 0),
        protocol_fee_share_bps: delayed::new(
            ProtocolFeeShareKey(),
            &id,
            checked_protocol_fee_share(bps::new(5_000)),
            0,
        ),
        id,
    }
}

/// Returns the share once it is at most `max_protocol_fee_share_bps`.
fun checked_protocol_fee_share(protocol_fee_share_bps: Bps): Bps {
    assert!(
        protocol_fee_share_bps.value() <= constants::max_protocol_fee_share_bps!(),
        blast_fun::errors::invalid_protocol_fee_share!(),
    );

    protocol_fee_share_bps
}

// === Test-Only Functions ===

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_fee_share_for_testing(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion<BLAST_FUN>,
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
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_protocol_fee_share(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// The configuration exactly as publication creates it, every delay at zero.
public fun new_publication_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new(ctx)
}

#[test_only]
/// Explicit zero-share fixture with account claims disabled.
public fun new_zero_fee_share_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new_zero_fee_share_with_signer_for_testing(vector[], ctx)
}

#[test_only]
/// Explicit zero-share fixture admitting `signer_public_key`, or no signer when it is empty,
/// with the signer delay raised to two days.
public fun new_zero_fee_share_with_signer_for_testing(
    signer_public_key: vector<u8>,
    ctx: &mut TxContext,
): RuntimeConfig {
    let id = object::new(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    let mut creator_claim_signers = delayed_set::new(ClaimSignerKey(), &id, 0);
    if (!signer_public_key.is_empty()) {
        creator_claim_signers.schedule_add(signer_public_key, &clock);
        creator_claim_signers.apply_add(signer_public_key, &clock);
    };
    creator_claim_signers.schedule_delay(initial_upgrade_delay_ms_for_testing(), &clock);
    creator_claim_signers.apply_delay(&clock);
    clock.destroy_for_testing();

    RuntimeConfig {
        creator_claim_signers,
        protocol_fee_share_bps: delayed::new(
            ProtocolFeeShareKey(),
            &id,
            bps::new(0),
            initial_upgrade_delay_ms_for_testing(),
        ),
        id,
    }
}

// === Imports ===

#[test_only]
use blast_admin::package_admin::initial_upgrade_delay_ms_for_testing;

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed},
    delayed_set::{Self, DelayedSet},
    package_version::PackageVersion
};

use blast_core::{blast_domain::{CancelAdmin, ClaimSignerAdmin, FeeAdmin}, bps::{Self, Bps}};

use blast_fun::{blast_fun::BLAST_FUN, constants};

use sui::clock::Clock;
