// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Launch policy each new launch snapshots.
module blast_fun::launch_config;

// === Public Types ===

/// The two trade rates change atomically.
public struct TradeFees has copy, drop, store {
    quote_fee_bps: Bps,
    meme_fee_bps: Bps
}

/// Admitted decimals, Quotes, and migration adapters; the trade fees; Blast's one-time migration
/// allocation; the SUI every launch pays at creation; and the Blast partners new launches may
/// name. Each creator picks the virtual Quote reserve their curve starts from.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, bool>,
    trade_fees: Delayed<TradeFeesKey, TradeFees>,
    migration_witnesses: DelayedSet<MigrationWitnessKey, TypeName>,
    protocol_allocation: Delayed<ProtocolAllocationKey, ProtocolAllocation>,
    /// In MIST.
    creation_fee: Delayed<CreationFeeKey, u64>,
}

/// Keys the trade fees' delayed lifecycle.
public struct TradeFeesKey() has copy, drop, store;

/// Keys the migration-adapter admissions' delayed lifecycle.
public struct MigrationWitnessKey() has copy, drop, store;

/// Keys Blast's migration allocation's delayed lifecycle.
public struct ProtocolAllocationKey() has copy, drop, store;

/// Keys the creation fee's delayed lifecycle.
public struct CreationFeeKey() has copy, drop, store;

/// Dynamic-field key of a Blast partner new launches may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(
        TradeFees { quote_fee_bps: bps::new(150), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(250), bps::new(150)),
        0,
        ctx,
    ));
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
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(
        meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999,
        blast_fun::errors::invalid_protocol_allocation!()
    );

    let value = allocation::protocol_allocation(meme_bps, quote_bps);
    self.protocol_allocation.schedule(value, delay_ms, clock);
}

/// Applies the scheduled protocol allocation permissionlessly once ready.
public fun apply_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.protocol_allocation.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.protocol_allocation.cancel();
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

    if (allowed) self.quotes.add(quote, true)
    else {
        self.quotes.remove(quote);
    };

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
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    assert!(
        quote_fee_bps.value() <= constants::max_launch_fee_bps!() && meme_fee_bps.value() <= constants::max_launch_fee_bps!(),
        blast_fun::errors::invalid_trade_fee_bps!()
    );

    self.trade_fees.schedule(TradeFees { quote_fee_bps, meme_fee_bps }, delay_ms, clock);
}

/// Applies the scheduled trade fees permissionlessly once ready.
public fun apply_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.trade_fees.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.trade_fees.cancel();
}

/// Sets the SUI, in MIST, every launch created afterward pays.
/// Schedules creation fee after the full administrative delay.
public fun schedule_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current();

    self.creation_fee.schedule(creation_fee, delay_ms, clock);
}

/// Applies the scheduled creation fee permissionlessly once ready.
public fun apply_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock,
) {
    package_version.assert_current();

    self.creation_fee.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current();

    self.creation_fee.cancel();
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

/// Admits a migration adapter's witness type after the applied admission notice. An admitted
/// adapter can start launches and receives their liquidity at migration; existing launches keep
/// their witness. Rescheduling a pending admission restarts its notice.
///
/// Framework types are rejected because anyone can construct them.
public fun schedule_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    clock: &Clock
) {
    package_version.assert_current();

    let witness = type_name::with_original_ids<MigrationWitness>();
    assert!(!witness.is_primitive(), blast_fun::errors::invalid_migration_witness_type!());

    let origin = type_name::original_id<MigrationWitness>();
    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_migration_witness_type!());

    self.migration_witnesses.schedule_add(witness, clock);
}

/// Permissionlessly applies the approved admission once ready.
public fun apply_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.apply_add(type_name::with_original_ids<MigrationWitness>(), clock);
}

/// Cancels a pending adapter admission, including after its threshold.
public fun cancel_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.cancel_add(type_name::with_original_ids<MigrationWitness>());
}

/// Immediately removes adapter authority and cancels any pending admission.
public fun remove_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.remove(type_name::with_original_ids<MigrationWitness>());
}

/// Proposes only the admission notice. Pending admissions keep their deadlines.
public fun schedule_migration_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.schedule_delay(delay_ms, clock);
}

/// Permissionlessly applies a ready admission-notice proposal.
public fun apply_migration_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    clock: &Clock
) {
    package_version.assert_current();

    self.migration_witnesses.apply_delay(clock);
}

/// Cancels only the admission-notice proposal.
public fun cancel_migration_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current();

    self.migration_witnesses.cancel_delay();
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

fun new(
    trade_fees: TradeFees,
    protocol_allocation: ProtocolAllocation,
    delay_ms: u64,
    ctx: &mut TxContext,
): LaunchConfig {
    let id = object::new(ctx);

    LaunchConfig {
        meme_decimals: vec_set::from_keys(vector[6, 9]),
        quotes: table::new(ctx),
        trade_fees: delayed::new(TradeFeesKey(), &id, trade_fees, delay_ms),
        migration_witnesses: delayed_set::new(MigrationWitnessKey(), &id, delay_ms),
        protocol_allocation: delayed::new(ProtocolAllocationKey(), &id, protocol_allocation, delay_ms),
        creation_fee: delayed::new(CreationFeeKey(), &id, 0, delay_ms),
        id,
    }
}

// === Test-Only Functions ===

#[test_only]
/// Reads the applied admission notice independently of pending admissions.
public fun migration_delay_ms_for_testing(self: &LaunchConfig): u64 {
    self.migration_witnesses.delay_ms()
}

#[test_only]
public fun migration_witnesses_for_testing(
    self: &LaunchConfig,
): &DelayedSet<MigrationWitnessKey, TypeName> {
    &self.migration_witnesses
}

#[test_only]
public fun set_migration_witness_allowed_for_testing<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    admin: &AdminWitness<AdapterAdmin>,
    allowed: bool,
    ctx: &mut TxContext
) {
    if (!allowed) {
        self.remove_migration_witness<MigrationWitness>(package_version, admin);
        return
    };
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
    let delay_ms = self.protocol_allocation.delay_ms();
    self.schedule_protocol_allocation(
        package_version,
        admin,
        meme_bps,
        quote_bps,
        delay_ms,
        &clock
    );
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
    let delay_ms = self.creation_fee.delay_ms();
    self.schedule_creation_fee(package_version, admin, creation_fee, delay_ms, &clock);
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
    let delay_ms = self.trade_fees.delay_ms();
    self.schedule_trade_fees(package_version, admin, quote_fee_bps, meme_fee_bps, delay_ms, &clock);
    clock.set_for_testing(172_800_000);
    self.apply_trade_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Explicit zero-fee fixture with the existing administrative notice.
public fun new_zero_fees_for_testing(ctx: &mut TxContext): LaunchConfig {
    new(
        TradeFees { quote_fee_bps: bps::new(0), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(0), bps::new(0)),
        172_800_000,
        ctx,
    )
}

#[test_only]
/// Shares a zero-fee genesis fixture without changing notice semantics.
public fun init_zero_fees_for_testing(ctx: &mut TxContext) {
    transfer::share_object(new(
        TradeFees { quote_fee_bps: bps::new(0), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(0), bps::new(0)),
        0,
        ctx,
    ));
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
    self.migration_witnesses.members().length()
}

// === Imports ===

use sui::{clock::Clock, dynamic_field, table::{Self, Table}, vec_set::{Self, VecSet}};

use blast_admin::{
    delayed::{Self, Delayed},
    delayed_set::{Self, DelayedSet},
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
