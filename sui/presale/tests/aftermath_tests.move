// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Aftermath preparation with its DAO-fee tier and the pool-creation capability it keeps, the
/// vault's terms and owner residuals, migration guards up to pool creation, and fee collection
/// from coins Aftermath sends to the vault's address. The venue interface is an `abort 0` link
/// stub, so pool creation itself is proven on mainnet dev-inspect instead.
module blast_presale::aftermath_tests;

// === Constants ===

const FEE_RECIPIENT: address = @0xFEE;
const PARTICIPANT: address = @0xA11CE;
const STRANGER: address = @0x5754;

/// The vault's fixed notice for a fee-split change.
const FEE_SPLIT_NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated sale token's.
public struct AFTERMATH_TESTS() has drop;

/// The fresh Aftermath LP coin a sale's pool creation is reserved for.
public struct LP() has drop;

/// Another LP coin, whose capability the sale did not reserve.
public struct OTHER_LP() has drop;

public struct OTHER_VENUE() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// Preparation records the DAO fee as the sale token's tier, with no tick spacing, keeps the
/// pool-creation capability it was given, and returns a ticket naming this venue.
fun prepare_records_the_dao_fee_tier_and_keeps_the_pool_creation_cap() {
    let mut ctx = tx_context::dummy();
    let version = blast_presale_package::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, Venue>(&mut ctx);
    let fee_policy = fee_policy::new_zero_fees_for_testing(&mut ctx);
    let mut venue_config = venue_config::new_for_testing(&mut ctx);
    let (treasury_cap, currency) = new_currency(&mut ctx);
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(&mut ctx);
    let create_pool_cap_id = object::id(&create_pool_cap);

    let ticket = aftermath::prepare<LP, _, QUOTE>(
        &version,
        &mut venue_config,
        &treasury_cap,
        create_pool_cap,
        venue_fixture::dao_fee_bps(),
    );

    let (tick_spacing, pool_fee_rate) = only_event<
        PoolTierReserved<AFTERMATH_TESTS, QUOTE, Venue>,
    >().pool_tier_reserved_fields();
    assert_eq!(vector[tick_spacing as u64, pool_fee_rate], vector[0, 200]);
    let (stored_tick_spacing, stored_fee_rate) = venue_config.pool_tier<AFTERMATH_TESTS>();
    assert_eq!(vector[stored_tick_spacing as u64, stored_fee_rate], vector[0, 200]);
    assert_eq!(
        only_event<PoolCreationReserved<LP, AFTERMATH_TESTS, QUOTE>>().pool_creation_reserved_fields(),
        create_pool_cap_id,
    );
    let initializer = presale::new(treasury_cap, &version, ticket, &creation_policy, &fee_policy);
    assert_eq!(initializer.venue(), type_name::with_original_ids<Venue>());

    destroy(initializer);
    destroy(currency);
    destroy(venue_config);
    destroy(fee_policy);
    destroy(creation_policy);
    destroy(version);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidDaoFee,
    location = blast_presale::aftermath,
)]
fun prepare_rejects_a_zero_dao_fee() {
    prepare_at_fee(0);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidDaoFee,
    location = blast_presale::aftermath,
)]
fun prepare_rejects_a_dao_fee_above_the_whole_amount() {
    prepare_at_fee(10_001);
}

#[test]
/// The DAO fee's lower bound is inclusive: one basis point prepares a sale.
fun prepare_accepts_one_basis_point() {
    prepare_at_fee(1);
}

#[test]
/// The DAO fee's upper bound is inclusive: the whole amount prepares a sale.
fun prepare_accepts_the_whole_amount() {
    prepare_at_fee(10_000);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale package version is refused before the fee or the capability is examined.
fun a_stale_version_cannot_prepare() {
    let mut ctx = tx_context::dummy();
    let mut version = blast_presale_package::new_for_testing(&mut ctx);
    version.set_for_testing(2);
    let mut venue_config = venue_config::new_for_testing(&mut ctx);
    let (treasury_cap, _currency) = new_currency(&mut ctx);

    destroy(
        aftermath::prepare<LP, _, QUOTE>(
            &version,
            &mut venue_config,
            &treasury_cap,
            amm_pool::create_pool_cap_for_testing(&mut ctx),
            0,
        ),
    );
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EVenueNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must admit this venue before its tickets can start a sale.
fun new_needs_blast_to_admit_the_venue() {
    let mut ctx = tx_context::dummy();
    let version = blast_presale_package::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, OTHER_VENUE>(&mut ctx);
    let fee_policy = fee_policy::new_zero_fees_for_testing(&mut ctx);
    let mut venue_config = venue_config::new_for_testing(&mut ctx);
    let (treasury_cap, _currency) = new_currency(&mut ctx);

    let ticket = aftermath::prepare<LP, _, QUOTE>(
        &version,
        &mut venue_config,
        &treasury_cap,
        amm_pool::create_pool_cap_for_testing(&mut ctx),
        venue_fixture::dao_fee_bps(),
    );
    destroy(presale::new(treasury_cap, &version, ticket, &creation_policy, &fee_policy));
    abort
}

#[test]
/// The vault Aftermath's migration builds starts with the sale's split and Blast's snapshotted
/// LP-fee rates, and its residuals wait for the sale's owner.
fun an_aftermath_vault_carries_the_sales_terms_and_owner_residuals() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );

    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);

    let (applied_split, state) = fixture.vault_state<AFTERMATH_TESTS>(vault_id);
    assert_eq!(applied_split, split_to(FEE_RECIPIENT));
    let mut expected = venue_fixture::lp_fee_bps();
    expected.append(vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()]);
    assert_eq!(state, expected);
    assert_eq!(
        fixture.claim_owner_balances<AFTERMATH_TESTS, AFTERMATH_TESTS>(sale_id, vault_id, &cap),
        vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()],
    );

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0, location = amm::pool_factory)]
/// Migration with the LP coin the sale reserved takes its capability and redeems the sale's
/// hand-off under this venue, reaching Aftermath's pool creation, where the link stub aborts.
fun migration_with_the_reserved_lp_coin_reaches_pool_creation() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );

    fixture.migrate_with_aftermath_pool<LP, AFTERMATH_TESTS>(sale_id);

    abort
}

#[test]
#[expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
/// The capability is kept under the LP coin that minted it, so a migration naming another LP coin
/// finds none and aborts before touching the sale.
fun migration_cannot_name_another_lp_coin() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );

    fixture.migrate_with_aftermath_pool<OTHER_LP, AFTERMATH_TESTS>(sale_id);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
/// Once a sale is cancelled its reserved capability serves nothing: the migration is refused in
/// the core before any pool is created.
fun a_cancelled_sale_cannot_migrate() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    fixture.cancel_at_the_lp_deadline<AFTERMATH_TESTS>(sale_id);

    fixture.migrate_with_aftermath_pool<LP, AFTERMATH_TESTS>(sale_id);

    abort
}

#[test]
/// Fee coins Aftermath sent to the vault's address are received, joined, and split like a
/// collected position's fees: Blast's LP-fee share to the treasury, the rest to the split.
fun collect_fees_receives_the_vaults_fee_coins_and_splits_them() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);
    let meme_fees = fixture.send_coins<AFTERMATH_TESTS>(
        vector[4_000, 6_000],
        vault_id.to_address(),
    );
    let quote_fees = fixture.send_coins<QUOTE>(vector[10_000], vault_id.to_address());

    fixture.collect_aftermath_fees(vault_id, &mut currency, meme_fees, quote_fees);

    // Blast takes 10% of the Meme and 20% of the Quote, rounded up.
    assert_eq!(fixture.take_coins<AFTERMATH_TESTS>(FEE_RECIPIENT), vector[9_000]);
    assert_eq!(fixture.take_coins<QUOTE>(FEE_RECIPIENT), vector[8_000]);
    let treasury = venue_fixture::treasury_address();
    assert_eq!(fixture.take_coins<AFTERMATH_TESTS>(treasury), vector[1_000]);
    assert_eq!(fixture.take_coins<QUOTE>(treasury), vector[2_000]);

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
/// A collection that lists no coins is valid and moves nothing.
fun an_empty_collection_moves_nothing() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);

    fixture.collect_aftermath_fees(vault_id, &mut currency, vector[], vector[]);

    assert!(fixture.take_coins<AFTERMATH_TESTS>(FEE_RECIPIENT).is_empty());
    assert!(fixture.take_coins<QUOTE>(FEE_RECIPIENT).is_empty());
    let (_, state) = fixture.vault_state<AFTERMATH_TESTS>(vault_id);
    let mut expected = venue_fixture::lp_fee_bps();
    expected.append(vector[venue_fixture::token_supply() / 2, venue_fixture::raise_target()]);
    assert_eq!(state, expected);

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
/// A coin owned by someone else cannot be received into the vault.
fun collect_fees_receives_only_coins_the_vault_owns() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);
    let stranger_coins = fixture.send_coins<QUOTE>(vector[10], STRANGER);

    fixture.collect_aftermath_fees(vault_id, &mut currency, vector[], stranger_coins);

    abort
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVenue, location = blast_vault::vault)]
/// Another venue's vault settles its fees only through that venue: the vault refuses Aftermath's
/// collection even when it lists no coins.
fun collect_fees_rejects_another_venues_vault() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_bluefin_sale(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_bluefin<AFTERMATH_TESTS>(sale_id);

    fixture.collect_aftermath_fees(vault_id, &mut currency, vector[], vector[]);

    abort
}

#[test]
/// Unreceived DAO-fee coins follow the split applied when they are received: after the notice
/// alone the old split still pays, and once applied the new one pays the coins received later.
fun a_split_change_applies_to_fee_coins_received_after_it() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);
    let fees = fixture.send_coins<QUOTE>(vector[10_000, 20_000], vault_id.to_address());
    fixture.schedule_fee_split<AFTERMATH_TESTS>(sale_id, vault_id, &cap, split_to(PARTICIPANT));
    fixture.set_time(venue_fixture_settled_at_ms() + FEE_SPLIT_NOTICE_MS);

    fixture.collect_aftermath_fees(vault_id, &mut currency, vector[], vector[fees[0]]);
    fixture.apply_aftermath_fee_split<AFTERMATH_TESTS>(vault_id);
    fixture.collect_aftermath_fees(vault_id, &mut currency, vector[], vector[fees[1]]);

    assert_eq!(fixture.take_coins<QUOTE>(FEE_RECIPIENT), vector[8_000]);
    assert_eq!(fixture.take_coins<QUOTE>(PARTICIPANT), vector[16_000]);
    let (applied_split, _) = fixture.vault_state<AFTERMATH_TESTS>(vault_id);
    assert_eq!(applied_split, split_to(PARTICIPANT));

    destroy(cap);
    destroy(currency);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
/// Applying needs a scheduled split.
fun apply_fee_split_needs_a_scheduled_split() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);

    fixture.apply_aftermath_fee_split<AFTERMATH_TESTS>(vault_id);

    abort
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVenue, location = blast_vault::vault)]
/// Aftermath cannot apply another venue's ready split: that venue settles first.
fun apply_fee_split_rejects_another_venues_ready_split() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, cap) = fixture.fund_bluefin_sale(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_bluefin<AFTERMATH_TESTS>(sale_id);
    fixture.schedule_fee_split<AFTERMATH_TESTS>(sale_id, vault_id, &cap, split_to(PARTICIPANT));
    fixture.set_time(venue_fixture_settled_at_ms() + FEE_SPLIT_NOTICE_MS);

    fixture.apply_aftermath_fee_split<AFTERMATH_TESTS>(vault_id);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale package version is refused before the vault's split is examined.
fun apply_fee_split_stale_version_precedes_the_split() {
    let mut fixture = venue_fixture::start();
    let (treasury_cap, mut currency) = fixture.new_currency(AFTERMATH_TESTS());
    let (sale_id, _cap) = fixture.fund_aftermath_sale<LP, _>(
        treasury_cap,
        &mut currency,
        split_to(FEE_RECIPIENT),
    );
    let vault_id = fixture.migrate_with_aftermath<AFTERMATH_TESTS>(sale_id);
    let scenario = fixture.scenario_mut();
    scenario.next_tx(STRANGER);
    let mut stale_version = blast_presale_package::new_for_testing(scenario.ctx());
    stale_version.set_for_testing(2);
    let vault_version = blast_vault_package::version_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut vault = scenario.take_shared_by_id<Vault<AFTERMATH_TESTS, QUOTE>>(vault_id);

    aftermath::apply_fee_split(&mut vault, &stale_version, &vault_version, &clock);

    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // The standard library's 0x1 sorts before the framework's 0x2, whatever address this
    // package builds at.
    assert!(sorts_before_for_testing<std::ascii::String, SUI>());
    assert!(!sorts_before_for_testing<SUI, std::ascii::String>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

#[test]
fun migration_postconditions_accept_exact_balances_fee_and_recipient() {
    aftermath::assert_pool_balances_for_testing(100, 100, 200, 200);
    aftermath::assert_dao_fee_terms_for_testing(200, 200, @0xA, @0xA);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EPoolMismatch,
    location = blast_presale::aftermath,
)]
fun migration_rejects_wrong_meme_balance() {
    aftermath::assert_pool_balances_for_testing(99, 100, 200, 200);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EPoolMismatch,
    location = blast_presale::aftermath,
)]
fun migration_rejects_wrong_quote_balance() {
    aftermath::assert_pool_balances_for_testing(100, 100, 199, 200);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EDaoFeePoolMismatch,
    location = blast_presale::aftermath,
)]
fun migration_rejects_wrong_dao_fee() {
    aftermath::assert_dao_fee_terms_for_testing(199, 200, @0xA, @0xA);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EDaoFeePoolMismatch,
    location = blast_presale::aftermath,
)]
fun migration_rejects_wrong_dao_fee_recipient() {
    aftermath::assert_dao_fee_terms_for_testing(200, 200, @0xB, @0xA);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EPoolMismatch,
    location = blast_presale::aftermath,
)]
fun meme_mismatch_rejects_before_reading_quote() {
    aftermath::assert_pool_short_circuit_for_testing();
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EDaoFeePoolMismatch,
    location = blast_presale::aftermath,
)]
fun fee_mismatch_rejects_before_reading_recipient() {
    aftermath::assert_dao_fee_short_circuit_for_testing();
}

// === Test Helpers ===

/// The whole LP-fee split to `recipient`.
fun split_to(recipient: address): FeeSplit {
    fee_split::new(vector[
        fee_split::route(fee_split::address_destination(recipient), bps::new(10_000)),
    ])
}

/// When the fixture's funded sales settle: their commitment window's end.
fun venue_fixture_settled_at_ms(): u64 { 100 }

/// Prepares an Aftermath sale at `dao_fee_bps`.
fun prepare_at_fee(dao_fee_bps: u16) {
    let mut ctx = tx_context::dummy();
    let version = blast_presale_package::new_for_testing(&mut ctx);
    let mut venue_config = venue_config::new_for_testing(&mut ctx);
    let (treasury_cap, currency) = new_currency(&mut ctx);

    destroy(
        aftermath::prepare<LP, _, QUOTE>(
            &version,
            &mut venue_config,
            &treasury_cap,
            amm_pool::create_pool_cap_for_testing(&mut ctx),
            dao_fee_bps,
        ),
    );

    destroy(treasury_cap);
    destroy(currency);
    destroy(venue_config);
    destroy(version);
}

/// A fresh sale token's zero-supply treasury cap and currency.
fun new_currency(ctx: &mut TxContext): (TreasuryCap<AFTERMATH_TESTS>, Currency<AFTERMATH_TESTS>) {
    let (currency_initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<AFTERMATH_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Aftermath presale test token".to_string(),
        b"".to_string(),
        ctx,
    );

    (treasury_cap, coin_registry::unwrap_for_testing(currency_initializer))
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use amm::pool as amm_pool;

use blast_core::{bps, fee_split::{Self, FeeSplit}};

use blast_presale::{
    aftermath::{Self, PoolCreationReserved, Venue, sorts_before_for_testing},
    blast_presale::Self as presale,
    blast_presale_package,
    creation_policy,
    fee_policy,
    venue_config::{Self, PoolTierReserved},
    venue_fixture::{Self, QUOTE}
};

use blast_vault::{blast_vault_package, vault::Vault};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock,
    coin::TreasuryCap,
    coin_registry::{Self, Currency},
    event,
    sui::SUI,
    test_utils
};
