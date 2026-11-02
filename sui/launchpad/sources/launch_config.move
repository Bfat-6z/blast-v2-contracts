// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Launch policy each new launch snapshots.
module blast_fun::launch_config;

// === Public Types ===

/// The two trade rates change atomically.
public struct TradeFees has copy, drop, store { quote_fee_bps: Bps, meme_fee_bps: Bps }

/// Admitted decimals, Quotes, and migration adapters; the trade fees; Blast's one-time migration
/// allocation; the SUI every launch pays at creation; and the Blast partners new launches may
/// name. Each creator picks the virtual Quote reserve their curve starts from.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, bool>,
    trade_fees: Delayed<TradeFees>,
    migration_witnesses: VecSet<TypeName>,
    pending_witnesses: VecMap<TypeName, Pending<bool>>,
    protocol_allocation: Delayed<ProtocolAllocation>,
    /// In MIST.
    creation_fee: Delayed<u64>,
}

/// Dynamic-field key of a Blast partner new launches may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets Blast's fee share of future launches' Meme supply and final Quote reserve. The shares
/// leave room for the curve and the pool; finalized launches keep their snapshotted shares.
/// Schedules protocol allocation after the full administrative delay.
public fun schedule_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    clock: &Clock,
) {
    package_version.assert_current();
    assert!(meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999, blast_fun::errors::invalid_protocol_allocation!());
    let value = allocation::protocol_allocation(meme_bps, quote_bps);
    assert!(value != self.protocol_allocation.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.protocol_allocation.schedule(value, package_version.admin_delay_ms(), clock);
    events::protocol_allocation_scheduled(meme_bps.value(), quote_bps.value(), ready_at_ms);
}

/// Applies the scheduled protocol allocation permissionlessly once ready.
public fun apply_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.protocol_allocation.apply(clock);
    let meme_bps = value.meme_bps();
    let quote_bps = value.quote_bps();
    events::protocol_allocation_set(meme_bps.value(), quote_bps.value());
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.protocol_allocation.cancel();
    let meme_bps = value.meme_bps();
    let quote_bps = value.quote_bps();
    events::protocol_allocation_cancelled(meme_bps.value(), quote_bps.value());
}

public fun set_meme_decimals_allowed(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    decimals: u8,
    allowed: bool,
) {
    package_version.assert_current();

    if (allowed) self.meme_decimals.insert(decimals) else self.meme_decimals.remove(&decimals);

    events::meme_decimals_set(decimals, allowed);
}

/// Admits or removes `Quote` for future launches; existing launches keep trading in it.
public fun set_quote_allowed<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current();
    let quote = type_name::with_original_ids<Quote>();

    if (allowed) self.quotes.add(quote, true) else { self.quotes.remove(quote); };

    events::quote_set<Quote>(allowed);
}

/// Sets the trade fees launches created afterward snapshot.
/// Schedules trade fees after the full administrative delay.
public fun schedule_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    clock: &Clock,
) {
    package_version.assert_current();
    assert!(quote_fee_bps.value() <= constants::max_launch_fee_bps!() && meme_fee_bps.value() <= constants::max_launch_fee_bps!(), blast_fun::errors::invalid_trade_fee_bps!());
    let value = TradeFees { quote_fee_bps, meme_fee_bps };
    assert!(value != self.trade_fees.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.trade_fees.schedule(value, package_version.admin_delay_ms(), clock);
    events::trade_fees_scheduled(quote_fee_bps.value(), meme_fee_bps.value(), ready_at_ms);
}

/// Applies the scheduled trade fees permissionlessly once ready.
public fun apply_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.trade_fees.apply(clock);
    let quote_fee_bps = value.quote_fee_bps;
    let meme_fee_bps = value.meme_fee_bps;
    events::launch_trade_fees_changed(quote_fee_bps.value(), meme_fee_bps.value());
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.trade_fees.cancel();
    let quote_fee_bps = value.quote_fee_bps;
    let meme_fee_bps = value.meme_fee_bps;
    events::trade_fees_cancelled(quote_fee_bps.value(), meme_fee_bps.value());
}

/// Sets the SUI, in MIST, every launch created afterward pays.
/// Schedules creation fee after the full administrative delay.
public fun schedule_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    let value = creation_fee;
    assert!(value != self.creation_fee.value(), blast_fun::errors::unchanged!());
    let ready_at_ms = self.creation_fee.schedule(value, package_version.admin_delay_ms(), clock);
    events::creation_fee_scheduled(creation_fee, ready_at_ms);
}

/// Applies the scheduled creation fee permissionlessly once ready.
public fun apply_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();
    let value = self.creation_fee.apply(clock);
    let creation_fee = value;
    events::creation_fee_changed(creation_fee);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();
    let value = self.creation_fee.cancel();
    let creation_fee = value;
    events::creation_fee_cancelled(creation_fee);
}

/// Lets new launches name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let key = PartnerKey(partner_id);

    if (self.id.has_dynamic_field(key)) {
        let acceptance_ends_at_ms: &mut u64 = self.id.dynamic_field_mut(key);
        assert!(*acceptance_ends_at_ms != std::u64::max_value!(), blast_fun::errors::unchanged!());
        *acceptance_ends_at_ms = std::u64::max_value!();
    } else {
        self.id.add_dynamic_field(key, std::u64::max_value!());
    };

    events::partner_added(partner_id);
}

/// Stops new launches naming `partner` after the notice Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Launches that already name it keep paying it.
public fun remove_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let now_at_ms = clock.timestamp_ms();
    self.assert_partner(partner_id, now_at_ms);
    let acceptance_ends_at_ms = now_at_ms + partners::delay_ms();

    let current: &mut u64 = self.id.dynamic_field_mut(PartnerKey(partner_id));
    assert!(*current == std::u64::max_value!(), blast_fun::errors::unchanged!());
    *current = acceptance_ends_at_ms;

    events::partner_removed(partner_id, acceptance_ends_at_ms);
}

/// Admits or removes a migration adapter's witness type. An admitted adapter can start launches
/// and receives their liquidity at migration; existing launches keep their witness.
///
/// Framework types are rejected because anyone can construct them.
/// Admits an adapter only after a full administrative notice period.
public fun schedule_migration_witness<MigrationWitness: drop>(self: &mut LaunchConfig, package_version: &PackageVersion, _: &AdminWitness<AdapterAdmin>, clock: &Clock) {
    package_version.assert_current();
    let witness = type_name::with_original_ids<MigrationWitness>();
    assert!(!witness.is_primitive(), blast_fun::errors::invalid_migration_witness_type!());
    let origin = type_name::original_id<MigrationWitness>();
    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_migration_witness_type!());
    assert!(!self.migration_witnesses.contains(&witness), blast_fun::errors::unchanged!());
    let pending = delayed::new_pending(true, package_version.admin_delay_ms(), clock);
    if (self.pending_witnesses.contains(&witness)) { self.pending_witnesses.remove(&witness); };
    self.pending_witnesses.insert(witness, pending);
    events::migration_witness_scheduled(witness, pending.ready_at_ms());
}

/// Permissionlessly applies the approved adapter admission once ready.
public fun apply_migration_witness<MigrationWitness: drop>(self: &mut LaunchConfig, package_version: &PackageVersion, clock: &Clock) {
    package_version.assert_current();
    let witness = type_name::with_original_ids<MigrationWitness>();
    self.pending_witnesses[&witness].take_ready(clock);
    self.pending_witnesses.remove(&witness);
    self.migration_witnesses.insert(witness);
    events::migration_witness_set<MigrationWitness>(true);
}

/// Cancels a pending adapter admission, including after its threshold.
public fun cancel_migration_witness<MigrationWitness: drop>(self: &mut LaunchConfig, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin>) {
    package_version.assert_current();
    let witness = type_name::with_original_ids<MigrationWitness>();
    self.pending_witnesses.remove(&witness);
    events::migration_witness_cancelled(witness);
}

/// Immediately removes adapter authority and cancels any pending admission.
public fun remove_migration_witness<MigrationWitness: drop>(self: &mut LaunchConfig, package_version: &PackageVersion, _: &AdminWitness<AdapterAdmin>) {
    package_version.assert_current();
    let witness = type_name::with_original_ids<MigrationWitness>();
    assert!(self.migration_witnesses.contains(&witness) || self.pending_witnesses.contains(&witness), blast_fun::errors::unchanged!());
    if (self.pending_witnesses.contains(&witness)) {
        self.pending_witnesses.remove(&witness);
        events::migration_witness_cancelled(witness);
    };
    if (self.migration_witnesses.contains(&witness)) {
        self.migration_witnesses.remove(&witness);
        events::migration_witness_set<MigrationWitness>(false);
    };
}

// === Package Functions ===

/// Checks the Quote, the adapter, and the decimals, and returns the trade fees.
public(package) fun snapshot_for_launch<Quote>(
    self: &LaunchConfig,
    migration_witness: TypeName,
    decimals: u8,
): (Bps, Bps) {
    assert!(
        self.quotes.contains(type_name::with_original_ids<Quote>()),
        blast_fun::errors::quote_not_allowed!(),
    );
    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());

    (self.trade_fees.value().quote_fee_bps, self.trade_fees.value().meme_fee_bps)
}

public(package) fun protocol_allocation(self: &LaunchConfig): ProtocolAllocation {
    self.protocol_allocation.value()
}

public(package) fun creation_fee(self: &LaunchConfig): u64 {
    self.creation_fee.value()
}

/// Aborts unless new launches may name `partner_id` at `now_at_ms`.
public(package) fun assert_partner(self: &LaunchConfig, partner_id: ID, now_at_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.has_dynamic_field(key), blast_fun::errors::partner_not_accepted!());
    let acceptance_ends_at_ms: u64 = *dynamic_field::borrow(&self.id, key);
    assert!(now_at_ms < acceptance_ends_at_ms, blast_fun::errors::partner_not_accepted!());
}

// === Private Functions ===

fun new(ctx: &mut TxContext): LaunchConfig {
    LaunchConfig {
        id: object::new(ctx),
        meme_decimals: vec_set::from_keys(vector[6, 9]),
        quotes: table::new(ctx),
        trade_fees: delayed::new(TradeFees { quote_fee_bps: bps::new(0), meme_fee_bps: bps::new(0) }),
        migration_witnesses: vec_set::empty(),
        pending_witnesses: vec_map::empty(),
        protocol_allocation: delayed::new(allocation::protocol_allocation(bps::new(0), bps::new(0))),
        creation_fee: delayed::new(0),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun set_migration_witness_allowed_for_testing<MigrationWitness: drop>(self: &mut LaunchConfig, package_version: &PackageVersion, admin: &AdminWitness<AdapterAdmin>, allowed: bool, ctx: &mut TxContext) {
    if (!allowed) { self.remove_migration_witness<MigrationWitness>(package_version, admin); return };
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_migration_witness<MigrationWitness>(package_version, admin, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_migration_witness<MigrationWitness>(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_allocation_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<TreasuryAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_protocol_allocation(package_version, admin, meme_bps, quote_bps, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_protocol_allocation(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_creation_fee_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_creation_fee(package_version, admin, creation_fee, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_creation_fee(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_trade_fees_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<FeeAdmin>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_trade_fees(package_version, admin, quote_fee_bps, meme_fee_bps, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_trade_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): LaunchConfig {
    new(ctx)
}

#[test_only]
public fun allowed_quote_count_for_testing(self: &LaunchConfig): u64 {
    self.quotes.length()
}

#[test_only]
public fun allowed_meme_decimals_count_for_testing(self: &LaunchConfig): u64 {
    self.meme_decimals.length()
}

#[test_only]
public fun rate_defaults_for_testing(self: &LaunchConfig): (u64, u64) {
    (self.trade_fees.value().quote_fee_bps.value(), self.trade_fees.value().meme_fee_bps.value())
}

#[test_only]
public fun allowed_migration_witness_count_for_testing(self: &LaunchConfig): u64 {
    self.migration_witnesses.length()
}

// === Imports ===

use sui::{
    vec_map::{Self, VecMap},
    clock::Clock, dynamic_field, table::{Self, Table}, vec_set::{Self, VecSet},
};

use blast_admin::{
    delayed::{Self, Delayed, Pending},
    blast_acl::AdminWitness,
};

use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    blast_fun_domain::{AdapterAdmin, CancelAdmin, FeeAdmin, ListingAdmin, TreasuryAdmin},
    bps::{Self, Bps},
    constants,
    events,
    blast_fun::{PackageVersion},
};

use blast_partners::blast_partners::{Self as partners, Partner};

use std::type_name::{Self, TypeName};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
