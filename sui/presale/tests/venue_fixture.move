// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Funded sales at each presale venue and the Blast objects their migrations and vaults use: the
/// package and vault versions, a fee policy whose LP-fee rates the vaults inherit, and the core
/// treasury. The venues' link stubs cannot create pools, so each migration runs the venue's
/// redemption and vault creation through its `migrate_for_testing` seam.
module blast_presale::venue_fixture;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const PARTICIPANT: address = @0xA11CE;
const KEEPER: address = @0x4EE9;
const TREASURY: address = @0x7EA5;

const TOKEN_SUPPLY: u64 = 1_000_000_000;
const RAISE_TARGET: u64 = 1_000_000;
const COMMITMENT_DURATION_MS: u64 = 100;
const LIQUIDITY_WINDOW_DURATION_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const LP_FEE_MEME_BPS: u64 = 1_000;
const LP_FEE_QUOTE_BPS: u64 = 2_000;
const TICK_SPACING: u32 = 60;
const POOL_FEE_RATE: u64 = 3_000;
const DAO_FEE_BPS: u16 = 200;

// === Test-Only Types ===

/// A second sale token, for tests that need two sales.
public struct VENUE_FIXTURE() has drop;

public struct QUOTE() has drop;

/// Stands in for a venue's locked position.
public struct TestPosition has key, store {
    id: UID,
}

public struct VenueFixture {
    scenario: Scenario,
    clock: Clock,
    package_version: PackageVersion,
    fee_policy: FeePolicy,
    venue_config: VenueConfig,
    vault_version: VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: Treasury,
    presale_registry: PresaleRegistry,
}

// === Test Helpers ===

/// Starts at clock zero with Blast's LP-fee rates set to `LP_FEE_MEME_BPS` and
/// `LP_FEE_QUOTE_BPS`, and no raise or token fee.
public fun start(): VenueFixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale_package::new_for_testing(scenario.ctx());
    let mut fee_policy = fee_policy::new_zero_fees_for_testing(scenario.ctx());
    fee_policy.set_fees_for_testing(
        &package_version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(0),
        bps::new(0),
        bps::new(LP_FEE_MEME_BPS),
        bps::new(LP_FEE_QUOTE_BPS),
        scenario.ctx(),
    );

    VenueFixture {
        clock: clock::create_for_testing(scenario.ctx()),
        fee_policy,
        venue_config: venue_config::new_for_testing(scenario.ctx()),
        vault_version: blast_vault_package::version_for_testing(scenario.ctx()),
        treasury: blast_treasury::new_for_testing(TREASURY, scenario.ctx()),
        presale_registry: presale::registry_for_testing(scenario.ctx()),
        package_version,
        scenario,
    }
}

/// A fresh zero-supply treasury cap and currency for the sale token whose one-time witness is
/// `otw`.
public fun new_currency<SaleToken: drop>(
    self: &mut VenueFixture,
    otw: SaleToken,
): (TreasuryCap<SaleToken>, Currency<SaleToken>) {
    let (currency_initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Venue fixture sale token".to_string(),
        b"".to_string(),
        self.scenario.ctx(),
    );

    (treasury_cap, coin_registry::unwrap_for_testing(currency_initializer))
}

/// Funds a sale migrating to Cetus, with a ticket `cetus::prepare` would return.
public fun fund_cetus_sale<SaleToken>(
    self: &mut VenueFixture,
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    fee_split: FeeSplit,
): (ID, PresaleCap) {
    let ticket = cetus::ticket_for_testing();

    self.fund_sale<_, cetus::Venue>(treasury_cap, currency, ticket, fee_split)
}

/// Funds a sale `bluefin::prepare` prepared at the fixture's tier.
public fun fund_bluefin_sale<SaleToken>(
    self: &mut VenueFixture,
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    fee_split: FeeSplit,
): (ID, PresaleCap) {
    let ticket = bluefin::prepare(
        &self.package_version,
        &mut self.venue_config,
        &treasury_cap,
        currency,
        TICK_SPACING,
        POOL_FEE_RATE,
    );

    self.fund_sale<_, bluefin::Venue>(treasury_cap, currency, ticket, fee_split)
}

/// Funds a sale `aftermath::prepare` prepared with a pool-creation capability of the LP coin `Lp`.
public fun fund_aftermath_sale<Lp, SaleToken>(
    self: &mut VenueFixture,
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    fee_split: FeeSplit,
): (ID, PresaleCap) {
    let ticket = aftermath::prepare<Lp, _, _>(
        &self.package_version,
        &mut self.venue_config,
        &treasury_cap,
        amm_pool::create_pool_cap_for_testing(self.scenario.ctx()),
        DAO_FEE_BPS,
    );

    self.fund_sale<_, aftermath::Venue>(treasury_cap, currency, ticket, fee_split)
}

/// Migrates the funded sale `sale_id` through `cetus` into a shared vault and returns its ID.
public fun migrate_with_cetus<SaleToken>(self: &mut VenueFixture, sale_id: ID): ID {
    self.scenario.next_tx(KEEPER);
    let mut registry = blast_vault_package::registry_for_testing<cetus::Venue, PackageWitness>(
        self.scenario.ctx(),
    );
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    let position = TestPosition { id: object::new(self.scenario.ctx()) };

    let vault_id = cetus::migrate_for_testing(
        &mut sale,
        &self.package_version,
        &self.fee_policy,
        &mut registry,
        &self.vault_version,
        &self.treasury,
        position,
        object::id_from_address(@0xB001),
        &self.clock,
        self.scenario.ctx(),
    );

    test_scenario::return_shared(sale);
    destroy(registry);

    vault_id
}

/// Migrates the funded sale `sale_id` through `bluefin` into a shared vault and returns its ID.
public fun migrate_with_bluefin<SaleToken>(self: &mut VenueFixture, sale_id: ID): ID {
    self.scenario.next_tx(KEEPER);
    let mut registry = blast_vault_package::registry_for_testing<bluefin::Venue, PackageWitness>(
        self.scenario.ctx(),
    );
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    let position = TestPosition { id: object::new(self.scenario.ctx()) };

    let vault_id = bluefin::migrate_for_testing(
        &mut sale,
        &self.package_version,
        &self.fee_policy,
        &mut registry,
        &self.vault_version,
        &self.treasury,
        position,
        object::id_from_address(@0xB001),
        &self.clock,
        self.scenario.ctx(),
    );

    test_scenario::return_shared(sale);
    destroy(registry);

    vault_id
}

/// Migrates the funded sale `sale_id` through `aftermath` into a shared vault and returns its ID.
public fun migrate_with_aftermath<SaleToken>(self: &mut VenueFixture, sale_id: ID): ID {
    self.scenario.next_tx(KEEPER);
    let mut registry = blast_vault_package::registry_for_testing<aftermath::Venue, PackageWitness>(
        self.scenario.ctx(),
    );
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    let position = TestPosition { id: object::new(self.scenario.ctx()) };

    let vault_id = aftermath::migrate_for_testing(
        &mut sale,
        &self.package_version,
        &self.fee_policy,
        &mut registry,
        &self.vault_version,
        &self.treasury,
        position,
        object::id_from_address(@0xB001),
        &self.clock,
        self.scenario.ctx(),
    );

    test_scenario::return_shared(sale);
    destroy(registry);

    vault_id
}

/// Runs `aftermath::migrate` on the funded sale `sale_id` with the LP coin `Lp`. The Aftermath
/// link stubs abort once it reaches pool creation, so a call that passes every guard before it
/// aborts there.
public fun migrate_with_aftermath_pool<Lp, SaleToken>(self: &mut VenueFixture, sale_id: ID) {
    self.scenario.next_tx(KEEPER);
    let mut registry = blast_vault_package::registry_for_testing<aftermath::Venue, PackageWitness>(
        self.scenario.ctx(),
    );
    let mut pool_registry = pool_registry::new_for_testing(self.scenario.ctx());
    let dao_fee_version = version::new_for_testing(self.scenario.ctx());
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);

    aftermath::migrate<Lp, _, _>(
        &mut sale,
        &self.package_version,
        &self.fee_policy,
        &mut self.venue_config,
        &mut pool_registry,
        &dao_fee_version,
        &mut registry,
        &self.vault_version,
        &self.treasury,
        &self.clock,
        self.scenario.ctx(),
    );

    test_scenario::return_shared(sale);
    destroy(pool_registry);
    destroy(dao_fee_version);
    destroy(registry);
}

/// Has a keeper cancel the funded sale `sale_id` at its LP deadline.
public fun cancel_at_the_lp_deadline<SaleToken>(self: &mut VenueFixture, sale_id: ID) {
    self.scenario.next_tx(KEEPER);
    self.clock.set_for_testing(COMMITMENT_DURATION_MS + LIQUIDITY_WINDOW_DURATION_MS);
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);

    sale.cancel_unlaunched(&self.package_version, &self.clock);
    assert!(sale.is_cancelled_for_testing());

    test_scenario::return_shared(sale);
}

/// Has the creator prove ownership of sale `sale_id` with `cap` and claim the owner's balances
/// of vault `vault_id`, returning the Meme and Quote claimed.
public fun claim_owner_balances<SaleToken, VaultToken>(
    self: &mut VenueFixture,
    sale_id: ID,
    vault_id: ID,
    cap: &PresaleCap,
): vector<u64> {
    self.scenario.next_tx(CREATOR);
    let sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    let mut vault = self.scenario.take_shared_by_id<Vault<VaultToken, QUOTE>>(vault_id);

    let proof = sale.prove_owner(&self.package_version, cap);
    let (meme, quote) = vault.claim_owner_balances(proof, &self.vault_version, self.scenario.ctx());
    let claimed = vector[meme.burn_for_testing(), quote.burn_for_testing()];

    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);

    claimed
}

/// Has the creator schedule `fee_split` on vault `vault_id` with the owner proof of sale
/// `sale_id`.
public fun schedule_fee_split<SaleToken>(
    self: &mut VenueFixture,
    sale_id: ID,
    vault_id: ID,
    cap: &PresaleCap,
    fee_split: FeeSplit,
) {
    self.scenario.next_tx(CREATOR);
    let sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    let mut vault = self.scenario.take_shared_by_id<Vault<SaleToken, QUOTE>>(vault_id);

    let proof = sale.prove_owner(&self.package_version, cap);
    vault.schedule_fee_split(proof, &self.vault_version, fee_split, &self.clock);

    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);
}

/// Has a keeper receive the listed DAO-fee coins into Aftermath vault `vault_id` and split them.
public fun collect_aftermath_fees<SaleToken>(
    self: &mut VenueFixture,
    vault_id: ID,
    currency: &mut Currency<SaleToken>,
    meme_fee_ids: vector<ID>,
    quote_fee_ids: vector<ID>,
) {
    self.scenario.next_tx(KEEPER);
    let mut vault = self.scenario.take_shared_by_id<Vault<SaleToken, QUOTE>>(vault_id);

    aftermath::collect_fees(
        &mut vault,
        &self.package_version,
        &self.vault_version,
        &self.treasury,
        currency,
        meme_fee_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<SaleToken>>(id)),
        quote_fee_ids.map!(|id| test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id)),
        self.scenario.ctx(),
    );

    test_scenario::return_shared(vault);
}

/// Has a keeper apply Aftermath vault `vault_id`'s ready fee split.
public fun apply_aftermath_fee_split<SaleToken>(self: &mut VenueFixture, vault_id: ID) {
    self.scenario.next_tx(KEEPER);
    let mut vault = self.scenario.take_shared_by_id<Vault<SaleToken, QUOTE>>(vault_id);

    aftermath::apply_fee_split(&mut vault, &self.package_version, &self.vault_version, &self.clock);

    test_scenario::return_shared(vault);
}

/// Mints one coin of `Asset` per amount and sends each to `recipient`, returning their IDs.
public fun send_coins<Asset>(
    self: &mut VenueFixture,
    amounts: vector<u64>,
    recipient: address,
): vector<ID> {
    self.scenario.next_tx(KEEPER);
    amounts.map!(|amount| {
        let coin = coin::mint_for_testing<Asset>(amount, self.scenario.ctx());
        let id = object::id(&coin);
        transfer::public_transfer(coin, recipient);
        id
    })
}

/// The Coin<Asset> amounts `owner` received since its last check, burning them.
public fun take_coins<Asset>(self: &mut VenueFixture, owner: address): vector<u64> {
    self.scenario.next_tx(owner);
    let ids = self.scenario.ids_for_sender<Coin<Asset>>();

    ids.map!(|id| self.scenario.take_from_sender_by_id<Coin<Asset>>(id).burn_for_testing())
}

/// The vault `vault_id`'s applied fee split, Blast's per-asset share, and owner balances.
public fun vault_state<SaleToken>(self: &mut VenueFixture, vault_id: ID): (FeeSplit, vector<u64>) {
    self.scenario.next_tx(KEEPER);
    let vault = self.scenario.take_shared_by_id<Vault<SaleToken, QUOTE>>(vault_id);

    let (meme_bps, quote_bps) = vault.protocol_bps_for_testing();
    let (owner_meme, owner_quote, _, _, _, _, _) = vault.balances_for_testing();
    let applied_split = vault.fee_split_for_testing();

    test_scenario::return_shared(vault);

    (applied_split, vector[meme_bps.value(), quote_bps.value(), owner_meme, owner_quote])
}

/// Moves the clock to `timestamp_ms`.
public fun set_time(self: &mut VenueFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun package_version(self: &VenueFixture): &PackageVersion {
    &self.package_version
}

public fun scenario_mut(self: &mut VenueFixture): &mut Scenario {
    &mut self.scenario
}

public fun end(self: VenueFixture) {
    let VenueFixture {
        scenario,
        clock,
        package_version,
        fee_policy,
        venue_config,
        vault_version,
        treasury,
        presale_registry,
    } = self;
    clock.destroy_for_testing();
    destroy(package_version);
    fee_policy.destroy_for_testing();
    destroy(venue_config);
    destroy(vault_version);
    destroy(treasury);
    destroy(presale_registry);
    scenario.end();
}

public fun token_supply(): u64 { TOKEN_SUPPLY }

public fun raise_target(): u64 { RAISE_TARGET }

public fun lp_fee_bps(): vector<u64> { vector[LP_FEE_MEME_BPS, LP_FEE_QUOTE_BPS] }

public fun creator(): address { CREATOR }

public fun treasury_address(): address { TREASURY }

public fun dao_fee_bps(): u16 { DAO_FEE_BPS }

/// Creates a sale of half the supply for buyers and half for the pool, one wallet raising
/// `RAISE_TARGET`, under a creation policy admitting `QUOTE` and `Venue`; shares it to open now,
/// funds it with one commitment of the whole raise, and settles it at the window's end. Returns
/// the sale's ID and the creator's cap.
fun fund_sale<SaleToken, Venue>(
    self: &mut VenueFixture,
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    ticket: VenueTicket<SaleToken, QUOTE>,
    fee_split: FeeSplit,
): (ID, PresaleCap) {
    self.scenario.next_tx(CREATOR);
    let starts_at_ms = self.clock.timestamp_ms();
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, Venue>(self.scenario.ctx());
    let version = &self.package_version;

    let mut initializer = presale::new(
        treasury_cap,
        version,
        ticket,
        &creation_policy,
        &self.fee_policy,
    );
    initializer.set_supply(version, TOKEN_SUPPLY, false);
    initializer.set_token_allocations(version, bps::new(5_000), bps::new(5_000), vector[]);
    initializer.set_raise(version, RAISE_TARGET, vector[]);
    initializer.set_windows(version, COMMITMENT_DURATION_MS, LIQUIDITY_WINDOW_DURATION_MS);
    initializer.set_eligibility(version, presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET));
    initializer.set_fee_split(version, fee_split);
    let (sale, cap) = initializer.finalize(version, &mut self.presale_registry, currency, self.scenario.ctx());
    let sale_id = object::id(&sale);
    sale.share(version, starts_at_ms, &self.clock);
    destroy(creation_policy);

    self.scenario.next_tx(PARTICIPANT);
    let mut sale = self.scenario.take_shared_by_id<Presale<SaleToken, QUOTE>>(sale_id);
    sale
        .commit_open(
            &self.package_version,
            coin::mint_for_testing<QUOTE>(RAISE_TARGET, self.scenario.ctx()),
            &self.clock,
            self.scenario.ctx(),
        )
        .destroy_zero();
    self.clock.set_for_testing(starts_at_ms + COMMITMENT_DURATION_MS);
    sale.settle(&self.package_version, &self.clock);
    test_scenario::return_shared(sale);

    (sale_id, cap)
}

// === Imports ===

use amm::{pool as amm_pool, pool_registry};

use blast_admin::{blast_acl, package_version::PackageVersion as VaultVersion};

use blast_core::{blast_treasury::{Self, Treasury}, bps, fee_split::FeeSplit, migration::VenueTicket};

use blast_presale::{
    aftermath,
    blast_presale::{Self as presale, PackageWitness, Presale, PresaleCap, PresaleRegistry},
    blast_presale_domain::FeeAdmin,
    blast_presale_package::{Self, PackageVersion},
    bluefin,
    cetus,
    creation_policy,
    fee_policy::{Self, FeePolicy},
    venue_config::{Self, VenueConfig}
};

use blast_vault::{blast_vault_package::{Self, BLAST_VAULT_PACKAGE}, vault::Vault};

use dao_fee_amm::version;

use std::unit_test::destroy;

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    test_scenario::{Self, Scenario}
};
