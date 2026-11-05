// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// T-010 conformance for the venue custody both release routes share: a sealed mock venue
/// prepares the coin, redeems the launch's hand-off in one transaction, and builds and shares a
/// `blast_vault` vault from the redeemed terms with its position attached, exactly as
/// `cetus::migrate` and `bluefin::migrate` do once their pools exist. The venue interfaces are
/// `abort 0` link stubs, so the routes themselves run against real venue bytecode in the
/// launchpad venue-fork harness.
module blast_fun_migrators::atomic_migration_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct ATOMIC_MIGRATION_TESTS has drop {}

public struct QUOTE() has drop;

/// The mock venue's sealed witness: it issues the ticket, redeems the hand-off, and keys the
/// position in the vault.
public struct Venue() has drop;

/// A venue the launch policy may admit but the vault registry never does.
public struct OtherVenue() has drop;

public struct MockPool has key { id: UID }

/// The venue position owns exactly the supplied principal; the vault settles the residuals.
public struct MockPosition<phantom Meme, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    liquidity: u128,
}

// === Tests ===

#[test]
fun a_migration_creates_a_vault_whose_event_carries_the_launch_terms() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    f.set_protocol_lp_fees(1_500, 1_500);
    let launch_id = f.open(owner_split(), false);
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    let (_, pooled_quote, _, pooled_meme) = launch.balances_for_testing();
    f.mock_migrate(&mut launch, &mut currency);

    assert!(launch.is_migrated_for_testing());
    let (_, quote_left, _, meme_left) = launch.balances_for_testing();
    assert_eq!(quote_left, 0);
    assert_eq!(meme_left, 0);
    let created = event::events_by_type<VaultCreated<ATOMIC_MIGRATION_TESTS, QUOTE, Venue>>();
    assert_eq!(created.length(), 1);
    test_scenario::return_shared(launch);
    launch_fixture::return_currency(currency);

    f.next_tx(TESTER);
    let mut vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    let pool_id = vault.pool_id();
    let position = vault.position_mut<_, _, _, MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>>(
        &Venue(),
        f.vault_version(),
    );
    assert_eq!(position.pool_id, pool_id);
    assert_eq!(position.meme.value() + RESIDUAL, pooled_meme);
    assert_eq!(position.quote.value() + RESIDUAL, pooled_quote);
    assert_eq!(pooled_quote, launch_fixture::graduation_target());
    let position_id = object::id(position);
    assert_eq!(
        bcs::to_bytes(&created[0]),
        vault_created_bytes(object::id(&vault), pool_id, position_id, launch_id, 1_500, option::none()),
    );
    assert_eq!(vault.fee_split_for_testing(), owner_split());
    let (meme_bps, quote_bps) = vault.protocol_bps_for_testing();
    assert_eq!(meme_bps.value(), 1_500);
    assert_eq!(quote_bps.value(), 1_500);
    test_scenario::return_shared(vault);

    f.end();
}

#[test]
fun protocol_residuals_are_paid_to_the_treasury_when_the_launch_names_no_partner() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    let launch_id = f.open(owner_split(), false);
    f.migrate_launch(launch_id);

    f.next_tx(TESTER);
    let vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    vault.assert_protocol_balances(0, 0);
    assert_eq!(f.coin_total<ATOMIC_MIGRATION_TESTS>(launch_fixture::treasury_address()), RESIDUAL);
    assert_eq!(f.coin_total<QUOTE>(launch_fixture::treasury_address()), RESIDUAL);
    let (owner_meme, owner_quote, _, _, _, _, _) = vault.balances_for_testing();
    assert_eq!(owner_meme, 0);
    assert_eq!(owner_quote, 0);
    test_scenario::return_shared(vault);

    f.end();
}

#[test]
fun protocol_residuals_wait_for_the_partner_the_launch_named() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    let launch_id = f.open(owner_split(), true);
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    f.mock_migrate(&mut launch, &mut currency);
    let created = event::events_by_type<VaultCreated<ATOMIC_MIGRATION_TESTS, QUOTE, Venue>>();
    test_scenario::return_shared(launch);
    launch_fixture::return_currency(currency);

    f.next_tx(TESTER);
    let mut vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    let partner_id = object::id(f.partner());
    let position_id = object::id(
        vault.position_mut<_, _, _, MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>>(
            &Venue(),
            f.vault_version(),
        ),
    );
    assert_eq!(
        bcs::to_bytes(&created[0]),
        vault_created_bytes(
            object::id(&vault),
            vault.pool_id(),
            position_id,
            launch_id,
            0,
            option::some(partner_id),
        ),
    );
    vault.assert_protocol_balances(RESIDUAL, RESIDUAL);
    assert!(!launch_fixture::has_coin<ATOMIC_MIGRATION_TESTS>(launch_fixture::treasury_address()));
    assert!(!launch_fixture::has_coin<QUOTE>(launch_fixture::treasury_address()));
    f.pay_partnered_protocol_fees(&mut vault);
    test_scenario::return_shared(vault);

    // The partner takes its share of each residual and the treasury the rest.
    f.next_tx(TESTER);
    let partner_cut = RESIDUAL * launch_fixture::partner_share_bps() / 10_000;
    assert_eq!(f.coin_total<ATOMIC_MIGRATION_TESTS>(launch_fixture::partner_recipient()), partner_cut);
    assert_eq!(f.coin_total<QUOTE>(launch_fixture::partner_recipient()), partner_cut);
    assert_eq!(
        f.coin_total<ATOMIC_MIGRATION_TESTS>(launch_fixture::treasury_address()),
        RESIDUAL - partner_cut,
    );
    assert_eq!(f.coin_total<QUOTE>(launch_fixture::treasury_address()), RESIDUAL - partner_cut);

    f.end();
}

#[test]
fun collections_split_through_the_vault_and_the_owner_claims_with_the_launch_proof() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    f.set_protocol_lp_fees(1_500, 1_500);
    let launch_id = f.open(owner_split(), false);
    f.migrate_launch(launch_id);
    let curve_fee_cap = f.claim_curve_fee_cap<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);

    f.next_tx(TESTER);
    let mut vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    f.mock_collect(&mut vault, &mut currency, 1_000, 2_000);

    // Blast's 15% of each asset, rounded up, is paid at once; the owner route accrues the rest.
    assert_eq!(event::events_by_type<FeesCollected<ATOMIC_MIGRATION_TESTS, QUOTE>>().length(), 1);
    vault.assert_protocol_balances(0, 0);
    let (owner_meme, owner_quote, _, _, _, _, _) = vault.balances_for_testing();
    assert_eq!(owner_meme, 850);
    assert_eq!(owner_quote, 1_700);
    test_scenario::return_shared(vault);
    launch_fixture::return_currency(currency);

    f.next_tx(launch_fixture::creator());
    assert_eq!(
        f.coin_total<ATOMIC_MIGRATION_TESTS>(launch_fixture::treasury_address()),
        RESIDUAL + 150,
    );
    assert_eq!(f.coin_total<QUOTE>(launch_fixture::treasury_address()), RESIDUAL + 300);
    let launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    let proof = launch.prove_owner(f.version(), &curve_fee_cap);
    let (meme, quote) = f.claim_owner_balances(&mut vault, proof);
    assert_eq!(meme.burn_for_testing(), 850);
    assert_eq!(quote.burn_for_testing(), 1_700);
    destroy(curve_fee_cap);
    test_scenario::return_shared(launch);
    test_scenario::return_shared(vault);

    f.end();
}

#[test]
fun auto_lp_and_buyback_run_through_the_migrated_vault() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    let split = fee_split::new(vector[
        fee_split::route(fee_split::auto_lp_destination(), bps::new(5_000)),
        fee_split::route(fee_split::burn_destination(), bps::new(5_000)),
    ]);
    let launch_id = f.open(split, false);
    let mut bought = f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    f.mock_migrate(&mut launch, &mut currency);
    test_scenario::return_shared(launch);
    launch_fixture::return_currency(currency);

    f.next_tx(TESTER);
    let mut vault = f.take_vault<ATOMIC_MIGRATION_TESTS, QUOTE>();
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    let supply_before = currency.total_supply().destroy_some();
    f.mock_collect(&mut vault, &mut currency, 1_000, 2_000);
    assert_eq!(currency.total_supply().destroy_some(), supply_before - 500);
    vault.assert_split_balances(500, 1_000, 1_000);

    // Auto-LP: the pool takes 400 Meme and 800 Quote into the position; the rest waits.
    let (mut meme, mut quote, receipt) = vault.take_auto_lp(&Venue(), f.vault_version());
    assert_eq!(meme.value(), 500);
    assert_eq!(quote.value(), 1_000);
    let (added_meme, added_quote) = (meme.split(400), quote.split(800));
    let position = vault.position_mut<_, _, _, MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>>(
        &Venue(),
        f.vault_version(),
    );
    position.meme.join(added_meme);
    position.quote.join(added_quote);
    vault.keep_auto_lp(&Venue(), f.vault_version(), receipt, meme, quote);
    assert_eq!(
        event::events_by_type<AutoLiquidityAdded<ATOMIC_MIGRATION_TESTS, QUOTE>>().length(),
        1,
    );

    // Buyback: 600 burn Quote buys 1,000 Meme, and the 100 Quote the pool leaves waits again.
    let (mut quote_in, receipt) = vault.take_buyback_quote(
        &Venue(),
        &blast_acl::witness_for_testing<BuybackAdmin>(),
        f.vault_version(),
        600,
    );
    let unspent_quote = quote_in.split(100);
    assert_eq!(quote_in.destroy_for_testing(), 500);
    let meme_out = bought.split(1_000, f.ctx()).into_balance();
    let supply_before_buyback = currency.total_supply().destroy_some();
    f.burn_buyback(&mut vault, receipt, &mut currency, meme_out, unspent_quote, 1_000);
    assert_eq!(currency.total_supply().destroy_some(), supply_before_buyback - 1_000);
    assert_eq!(event::events_by_type<BuybackBurned<ATOMIC_MIGRATION_TESTS, QUOTE>>().length(), 1);
    vault.assert_split_balances(100, 200, 500);
    destroy(bought);
    test_scenario::return_shared(vault);
    launch_fixture::return_currency(currency);

    f.end();
}

#[test, expected_failure(
    abort_code = blast_core::errors::EWrongVenue,
    location = blast_core::migration,
)]
fun the_hand_off_redeems_only_under_the_venue_that_issued_the_ticket() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    let launch_id = f.open(owner_split(), false);
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    let (version, config, _, _, _, clock, ctx) = f.migration_inputs();
    let (_meme, _quote, _terms) = launch
        .migrate(version, config, &mut currency, clock, ctx)
        .redeem(OtherVenue());

    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_vault::errors::EUnadmittedVenue,
    location = blast_vault::blast_vault_package,
)]
fun the_vault_registry_refuses_a_venue_the_launch_policy_admitted() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    f.admit_launch_venue<OtherVenue>();
    let (ticket, treasury_cap) = f.new_ticket(
        test_utils::create_one_time_witness<ATOMIC_MIGRATION_TESTS>(),
        true,
    );
    let venue_ticket = migration::issue_ticket<_, QUOTE, _>(OtherVenue());
    let launch_id = f.open_launch(ticket, treasury_cap, venue_ticket, owner_split(), false);
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    let (version, config, registry, vault_version, _, clock, ctx) = f.migration_inputs();
    let (meme, quote, terms) = launch
        .migrate(version, config, &mut currency, clock, ctx)
        .redeem(OtherVenue());
    let _vault = vault::new<ATOMIC_MIGRATION_TESTS, QUOTE, _>(
        registry,
        &OtherVenue(),
        vault_version,
        terms,
        @0x9001.to_id(),
    );

    destroy(meme);
    destroy(quote);
    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_vault::errors::EZeroLiquidity,
    location = blast_vault::vault,
)]
fun zero_liquidity_aborts_the_migration() {
    let mut f = launch_fixture::start<QUOTE, Venue>();
    let launch_id = f.open(owner_split(), false);
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    let (version, config, registry, vault_version, treasury, clock, ctx) = f.migration_inputs();
    launch.mock_adapter_with(
        version,
        config,
        &mut currency,
        registry,
        vault_version,
        treasury,
        0,
        clock,
        ctx,
    );

    abort EUnexpectedSuccess
}

// === Test Helpers ===

/// The mock venue redeems the hand-off with its sealed witness, seeds a position, and builds and
/// shares the vault from the redeemed terms; it returns no protected value.
public fun mock_adapter(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    registry: &mut VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.mock_adapter_with(version, config, currency, registry, vault_version, treasury, 1, clock, ctx)
}

/// Migrates, keeps `RESIDUAL` atoms of each asset as the pool's residuals, seeds a mock position
/// holding the rest at `liquidity`, builds the vault from the redeemed terms with the position
/// attached, then shares the vault and the pool.
fun mock_adapter_with(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    registry: &mut VaultRegistry,
    vault_version: &VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    liquidity: u128,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut meme, mut quote, terms) = launch.migrate(version, config, currency, clock, ctx).redeem(Venue());
    let residual_meme = meme.split(RESIDUAL);
    let residual_quote = quote.split(RESIDUAL);
    let pool = MockPool { id: object::new(ctx) };
    let pool_id = object::id(&pool);
    let position = MockPosition { id: object::new(ctx), pool_id, meme, quote, liquidity };
    vault::new<_, _, _>(registry, &Venue(), vault_version, terms, pool_id).share_with_position(
        &Venue(),
        treasury,
        position,
        liquidity,
        residual_meme,
        residual_quote,
        ctx,
    );
    transfer::share_object(pool);
}

/// Prepares a burn-only coin at the mock venue and opens its launch with `fee_split`.
fun open(f: &mut LaunchFixture, fee_split: FeeSplit, names_partner: bool): ID {
    let (ticket, treasury_cap) = f.new_ticket(
        test_utils::create_one_time_witness<ATOMIC_MIGRATION_TESTS>(),
        true,
    );
    let venue_ticket = migration::issue_ticket<_, QUOTE, _>(Venue());

    f.open_launch(ticket, treasury_cap, venue_ticket, fee_split, names_partner)
}

/// Graduates the launch and migrates it through the mock venue in the next transaction.
fun migrate_launch(f: &mut LaunchFixture, launch_id: ID) {
    destroy(f.graduate<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id));

    f.next_tx(TESTER);
    let mut launch = f.take_launch<ATOMIC_MIGRATION_TESTS, QUOTE>(launch_id);
    let mut currency = f.take_currency<ATOMIC_MIGRATION_TESTS>();
    f.mock_migrate(&mut launch, &mut currency);
    test_scenario::return_shared(launch);
    launch_fixture::return_currency(currency);
}

/// Runs the mock venue's migration with the fixture's route inputs.
fun mock_migrate(
    f: &mut LaunchFixture,
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
) {
    let (version, config, registry, vault_version, treasury, clock, ctx) = f.migration_inputs();
    launch.mock_adapter(version, config, currency, registry, vault_version, treasury, clock, ctx);
}

/// Splits one collection of the mock position's fees through the vault, as a venue does.
fun mock_collect(
    f: &mut LaunchFixture,
    vault: &mut Vault<ATOMIC_MIGRATION_TESTS, QUOTE>,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    meme: u64,
    quote: u64,
) {
    let (vault_version, treasury, ctx) = f.collection_inputs();
    vault.split_fees(
        &Venue(),
        vault_version,
        treasury,
        currency,
        balance::create_for_testing(meme),
        balance::create_for_testing(quote),
        ctx,
    );
}

/// Burns the Meme a mock buyback swap returned, as a venue does.
fun burn_buyback(
    f: &mut LaunchFixture,
    vault: &mut Vault<ATOMIC_MIGRATION_TESTS, QUOTE>,
    receipt: BuybackReceipt,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    meme: Balance<ATOMIC_MIGRATION_TESTS>,
    unspent_quote: Balance<QUOTE>,
    min_meme_out: u64,
) {
    let (vault_version, _, ctx) = f.collection_inputs();
    vault.burn_buyback(
        &Venue(),
        vault_version,
        receipt,
        currency,
        meme,
        unspent_quote,
        min_meme_out,
        ctx,
    );
}

/// Pays the protocol balances held for the launch's partner; anyone may.
fun pay_partnered_protocol_fees(
    f: &mut LaunchFixture,
    vault: &mut Vault<ATOMIC_MIGRATION_TESTS, QUOTE>,
) {
    let (vault_version, treasury, partner, ctx) = f.partner_payment_inputs();

    vault.pay_protocol_fees_with_partner(vault_version, treasury, partner, ctx);
}

/// Claims the owner's balances with `proof`.
fun claim_owner_balances(
    f: &mut LaunchFixture,
    vault: &mut Vault<ATOMIC_MIGRATION_TESTS, QUOTE>,
    proof: OwnerProof,
): (Coin<ATOMIC_MIGRATION_TESTS>, Coin<QUOTE>) {
    let (vault_version, _, ctx) = f.collection_inputs();

    vault.claim_owner_balances(proof, vault_version, ctx)
}

/// Asserts the protocol ledger holds `meme` and `quote` and no SUI.
fun assert_protocol_balances(vault: &Vault<ATOMIC_MIGRATION_TESTS, QUOTE>, meme: u64, quote: u64) {
    let (protocol_meme, protocol_quote, protocol_sui) = vault.protocol_balances_for_testing();
    assert_eq!(protocol_meme, meme);
    assert_eq!(protocol_quote, quote);
    assert_eq!(protocol_sui, 0);
}

/// Asserts the auto-LP balances and the burn Quote, with nothing owed to the owner or rewards.
fun assert_split_balances(
    vault: &Vault<ATOMIC_MIGRATION_TESTS, QUOTE>,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    burn_quote: u64,
) {
    let (owner_meme, owner_quote, lp_meme, lp_quote, rewards_meme, rewards_quote, burn) = vault
        .balances_for_testing();
    assert_eq!(owner_meme, 0);
    assert_eq!(owner_quote, 0);
    assert_eq!(lp_meme, auto_lp_meme);
    assert_eq!(lp_quote, auto_lp_quote);
    assert_eq!(rewards_meme, 0);
    assert_eq!(rewards_quote, 0);
    assert_eq!(burn, burn_quote);
}

/// The total value of every `Asset` coin `owner` received in earlier transactions.
fun coin_total<Asset>(f: &LaunchFixture, owner: address): u64 {
    test_scenario::ids_for_address<Coin<Asset>>(owner).fold!(0, |total, id| {
        let coin = f.scenario().take_from_address_by_id<Coin<Asset>>(owner, id);
        let value = coin.value();
        test_scenario::return_to_address(owner, coin);
        total + value
    })
}

/// The BCS of the `VaultCreated` event the mock migration emits for the fixture launch: its
/// identities, the mock liquidity, the terms the launch sealed (its ID and package witness, the
/// owner split, Blast's LP-fee share, the partner, and protocol residuals), and the residuals.
fun vault_created_bytes(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    launch_id: ID,
    protocol_bps: u64,
    partner_id: Option<ID>,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&vault_id);
    bytes.append(bcs::to_bytes(&pool_id));
    bytes.append(bcs::to_bytes(&position_id));
    bytes.append(bcs::to_bytes(&1u128));
    bytes.append(bcs::to_bytes(&launch_id));
    bytes.append(bcs::to_bytes(&type_name::with_original_ids<blast_fun::blast_fun::PackageWitness>()));
    bytes.append(bcs::to_bytes(&owner_split()));
    bytes.append(bcs::to_bytes(&bps::new(protocol_bps)));
    bytes.append(bcs::to_bytes(&bps::new(protocol_bps)));
    bytes.append(bcs::to_bytes(&partner_id));
    bytes.append(bcs::to_bytes(&migration::residuals_to_protocol()));
    let residual = RESIDUAL;
    bytes.append(bcs::to_bytes(&residual));
    bytes.append(bcs::to_bytes(&residual));

    bytes
}

/// Everything after Blast's share accrues to the owner.
fun owner_split(): FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

// === Constants ===

const TESTER: address = @0xB1A57;

/// Atoms of each asset the mock pool leaves as migration residuals.
const RESIDUAL: u64 = 10;

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Imports ===

use blast_admin::{blast_acl, package_version::{PackageVersion, PackageVersion as VaultVersion}};

use blast_core::{
    blast_domain::BuybackAdmin,
    blast_treasury::Treasury,
    bps,
    fee_split::{Self, FeeSplit},
    migration,
    owner_proof::OwnerProof
};

use blast_fun::{
    blast_fun::BLAST_FUN,
    launch::{Self, Launch},
    launch_config::LaunchConfig
};

use blast_fun_migrators::launch_fixture::{Self, LaunchFixture};

use blast_vault::{
    blast_vault_events::{AutoLiquidityAdded, BuybackBurned, FeesCollected, VaultCreated},
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, BuybackReceipt, Vault}
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    event,
    test_scenario,
    test_utils
};

use fun mock_adapter as Launch.mock_adapter;
use fun mock_adapter_with as Launch.mock_adapter_with;

use fun assert_protocol_balances as Vault.assert_protocol_balances;
use fun assert_split_balances as Vault.assert_split_balances;

use fun burn_buyback as LaunchFixture.burn_buyback;
use fun claim_owner_balances as LaunchFixture.claim_owner_balances;
use fun coin_total as LaunchFixture.coin_total;
use fun migrate_launch as LaunchFixture.migrate_launch;
use fun mock_collect as LaunchFixture.mock_collect;
use fun mock_migrate as LaunchFixture.mock_migrate;
use fun open as LaunchFixture.open;
use fun pay_partnered_protocol_fees as LaunchFixture.pay_partnered_protocol_fees;
