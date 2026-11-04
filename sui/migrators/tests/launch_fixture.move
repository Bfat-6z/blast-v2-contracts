// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Launch intake and vault custody shared by the migration suites: a zero-fee launch policy that
/// admits one Quote and one venue, a vault registry that admits the same venue, the treasury and
/// a partner, and one launch started from a venue's ticket that a buyer graduates to
/// MigrationReady.
module blast_fun_migrators::launch_fixture;

// === Test-Only Types ===

/// Every object a venue route reads, held unshared so each test states only its own delta.
public struct LaunchFixture {
    scenario: Scenario,
    version: PackageVersion<BLAST_FUN>,
    migrators_version: MigratorsVersion,
    config: LaunchConfig,
    runtime: RuntimeConfig,
    launch_registry: LaunchRegistry,
    registry: VaultRegistry,
    vault_version: VaultVersion<BLAST_VAULT_PACKAGE>,
    treasury: Treasury,
    partner: Partner,
    clock: Clock,
}

// === Test Helpers ===

/// Starts the fixture with `Quote` and `Venue` admitted by the launch policy and `Venue` admitted
/// by the vault registry, at zero trade fees and a zero Blast LP-fee share. The shared
/// `VenueConfig` exists from the first transaction on.
public fun start<Quote, Venue: drop>(): LaunchFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = scenario.ctx();
    let version = package_version::version_for_testing(ctx);
    let mut config = launch_config::new_zero_fees_for_testing(ctx);
    config.set_quote_allowed<Quote>(&version, &blast_acl::witness_for_testing<ListingAdmin>(), true);
    venue_config::init_for_testing(ctx);

    let mut fixture = LaunchFixture {
        migrators_version: migrators_version::new_for_testing(ctx),
        runtime: runtime_config::new_zero_fee_share_for_testing(ctx),
        launch_registry: launch::registry_for_testing(ctx),
        registry: blast_vault_package::registry_for_testing<Venue, launch::PackageWitness>(ctx),
        vault_version: blast_vault_package::version_for_testing(ctx),
        treasury: blast_treasury::new_for_testing(TREASURY, ctx),
        partner: blast_partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_SHARE_BPS, ctx),
        clock: clock::create_for_testing(ctx),
        scenario,
        version,
        config,
    };
    fixture.admit_launch_venue<Venue>();
    fixture.scenario.next_tx(ADMIN);

    fixture
}

/// Admits `Venue` for new launches; the vault registry is unchanged.
public fun admit_launch_venue<Venue: drop>(self: &mut LaunchFixture) {
    self
        .config
        .set_venue_allowed_for_testing<Venue>(
            &self.version,
            &blast_acl::witness_for_testing<AdapterAdmin>(),
            true,
            self.scenario.ctx(),
        );
}

/// Applies Blast's LP-fee share that migrations seal into new vaults' terms.
public fun set_protocol_lp_fees(self: &mut LaunchFixture, meme_bps: u64, quote_bps: u64) {
    self
        .config
        .set_protocol_lp_fees_for_testing(
            &self.version,
            &blast_acl::witness_for_testing<FeeAdmin>(),
            bps::new(meme_bps),
            bps::new(quote_bps),
            self.scenario.ctx(),
        );
}

/// Registers the generated coin and mints its supply into a ticket, returning the treasury
/// capability a venue prepares the coin with. Its currency reaches the Coin Registry in the next
/// transaction.
public fun new_ticket<Meme: drop>(
    self: &mut LaunchFixture,
    otw: Meme,
    burnable: bool,
): (LaunchTicket<Meme>, TreasuryCap<Meme>) {
    launch_ticket::new(
        otw,
        9,
        b"TEST".to_string(),
        b"Migrator fixture".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        burnable,
        0,
        self.scenario.ctx(),
    )
}

/// Starts the launch from the venue's ticket with `fee_split`, naming the fixture's partner when
/// `names_partner`, finalizes it once the Coin Registry holds the currency, and shares it. Returns
/// the launch's ID.
public fun open_launch<Meme, Quote>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<Meme>,
    treasury_cap: TreasuryCap<Meme>,
    venue_ticket: VenueTicket<Meme, Quote>,
    fee_split: FeeSplit,
    names_partner: bool,
): ID {
    self.scenario.next_tx(ADMIN);
    let mut currency = self.take_currency<Meme>();
    let mut initializer = launch::new(
        ticket,
        treasury_cap,
        &self.version,
        &self.config,
        venue_ticket,
    );
    initializer.set_virtual_quote(&self.version, VIRTUAL_QUOTE);
    initializer.set_graduation_target(&self.version, TARGET);
    initializer.set_allocation_plan(
        &self.version,
        allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[]),
    );
    initializer.set_lp_fee_split(&self.version, fee_split);
    if (names_partner) {
        self
            .config
            .add_partner(&self.version, &blast_acl::witness_for_testing<FeeAdmin>(), &self.partner);
        initializer.set_partner(&self.version, &self.config, &self.partner, &self.clock);
    };

    let creation_fee = coin::zero(self.scenario.ctx());
    let launch = initializer.finalize(
        &self.version,
        &mut self.launch_registry,
        &mut currency,
        &self.config,
        creation_fee,
    );
    let launch_id = object::id(&launch);
    launch.share(&self.version, &self.clock);
    return_currency(currency);

    launch_id
}

/// Buys past the graduation target in the next transaction, making the launch MigrationReady,
/// and returns the Meme bought; the Quote refund is discarded. Ends on the buyer's transaction.
public fun graduate<Meme, Quote>(self: &mut LaunchFixture, launch_id: ID): Coin<Meme> {
    self.scenario.next_tx(BUYER);
    let mut launch = self.take_launch<Meme, Quote>(launch_id);
    let quote = coin::mint_for_testing<Quote>(TARGET + VIRTUAL_QUOTE, self.scenario.ctx());
    let (meme, refund) = launch.buy(&self.version, &self.runtime, quote, 1, self.scenario.ctx());
    destroy(refund);
    test_scenario::return_shared(launch);

    meme
}

/// Claims the launch's creator capabilities as its creator in the next transaction, keeping the
/// curve-fee cap the vault's owner proofs need and discarding the metadata cap.
public fun claim_curve_fee_cap<Meme, Quote>(
    self: &mut LaunchFixture,
    launch_id: ID,
): CurveFeeCap<Meme> {
    self.scenario.next_tx(CREATOR);
    let mut launch = self.take_launch<Meme, Quote>(launch_id);
    let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
        &self.version,
        &self.runtime,
        option::none(),
        &self.clock,
        self.scenario.ctx(),
    );
    destroy(metadata_cap);
    test_scenario::return_shared(launch);

    curve_fee_cap
}

/// Moves to the next transaction as `sender`.
public fun next_tx(self: &mut LaunchFixture, sender: address) {
    self.scenario.next_tx(sender);
}

/// Takes the shared launch.
public fun take_launch<Meme, Quote>(self: &LaunchFixture, launch_id: ID): Launch<Meme, Quote> {
    self.scenario.take_shared_by_id(launch_id)
}

/// Takes the Meme currency from the Coin Registry.
public fun take_currency<Meme>(self: &LaunchFixture): Currency<Meme> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

/// Returns the Meme currency to the Coin Registry.
public fun return_currency<Meme>(currency: Currency<Meme>) {
    test_scenario::return_to_address(COIN_REGISTRY, currency);
}

/// Takes the one shared vault of the pair.
public fun take_vault<Meme, Quote>(self: &LaunchFixture): Vault<Meme, Quote> {
    self.scenario.take_shared()
}

/// Takes the shared venue config.
public fun take_venue_config(self: &LaunchFixture): VenueConfig {
    self.scenario.take_shared()
}

/// The inputs every venue migration route reads: the launch generation and policy, the vault
/// registry and generation, the treasury, and the transaction context.
public fun migration_inputs(
    self: &mut LaunchFixture,
): (
    &PackageVersion<BLAST_FUN>,
    &LaunchConfig,
    &mut VaultRegistry,
    &VaultVersion<BLAST_VAULT_PACKAGE>,
    &Treasury,
    &Clock,
    &mut TxContext,
) {
    (
        &self.version,
        &self.config,
        &mut self.registry,
        &self.vault_version,
        &self.treasury,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// The inputs every vault collection reads: the vault generation, the treasury, and the
/// transaction context.
public fun collection_inputs(
    self: &mut LaunchFixture,
): (&VaultVersion<BLAST_VAULT_PACKAGE>, &Treasury, &mut TxContext) {
    (&self.vault_version, &self.treasury, self.scenario.ctx())
}

/// The inputs paying Blast fees held for the fixture's partner reads: the vault generation, the
/// treasury, the partner, and the transaction context.
public fun partner_payment_inputs(
    self: &mut LaunchFixture,
): (&VaultVersion<BLAST_VAULT_PACKAGE>, &Treasury, &Partner, &mut TxContext) {
    (&self.vault_version, &self.treasury, &self.partner, self.scenario.ctx())
}

/// Whether `owner` received a coin of `Asset` in an earlier transaction.
public fun has_coin<Asset>(owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<Asset>>(owner)
}

public fun scenario(self: &LaunchFixture): &Scenario { &self.scenario }

public fun ctx(self: &mut LaunchFixture): &mut TxContext { self.scenario.ctx() }

public fun version(self: &LaunchFixture): &PackageVersion<BLAST_FUN> { &self.version }

public fun migrators_version(self: &LaunchFixture): &MigratorsVersion { &self.migrators_version }

public fun migrators_version_mut(self: &mut LaunchFixture): &mut MigratorsVersion {
    &mut self.migrators_version
}

public fun config(self: &LaunchFixture): &LaunchConfig { &self.config }

public fun vault_version(self: &LaunchFixture): &VaultVersion<BLAST_VAULT_PACKAGE> {
    &self.vault_version
}

public fun treasury(self: &LaunchFixture): &Treasury { &self.treasury }

public fun partner(self: &LaunchFixture): &Partner { &self.partner }

/// Destroys every fixture object and ends the scenario.
public fun end(self: LaunchFixture) {
    let LaunchFixture {
        scenario,
        version,
        migrators_version,
        config,
        runtime,
        launch_registry,
        registry,
        vault_version,
        treasury,
        partner,
        clock,
    } = self;
    destroy(version);
    destroy(migrators_version);
    destroy(config);
    destroy(runtime);
    destroy(launch_registry);
    destroy(registry);
    destroy(vault_version);
    destroy(treasury);
    destroy(partner);
    clock.destroy_for_testing();
    scenario.end();
}

/// The launch's creator recipient.
public fun creator(): address { CREATOR }

/// The buyer that graduates every fixture launch.
public fun buyer(): address { BUYER }

/// The treasury's destination address.
public fun treasury_address(): address { TREASURY }

/// The partner's payout address.
public fun partner_recipient(): address { PARTNER_RECIPIENT }

/// The partner's share of each Blast fee, in basis points.
public fun partner_share_bps(): u64 { PARTNER_SHARE_BPS }

/// The Quote a graduated launch hands to its pool: the whole target, at zero trade fees.
public fun graduation_target(): u64 { TARGET }

// === Constants ===

const ADMIN: address = @0xAD;

const BUYER: address = @0xB0B;

/// The ticket's creator recipient, who claims the launch's creator capabilities.
const CREATOR: address = @0xC0FFEE;

const TREASURY: address = @0x7EA5;

const PARTNER_RECIPIENT: address = @0xBA27;

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const PARTNER_SHARE_BPS: u64 = 3_000;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const TARGET: u64 = 25_000_000;

// === Imports ===

use blast_admin::{blast_acl, package_version::{PackageVersion, PackageVersion as VaultVersion}};

use blast_core::{
    blast_domain::{AdapterAdmin, FeeAdmin, ListingAdmin},
    blast_treasury::{Self, Treasury},
    bps,
    fee_split::FeeSplit,
    migration::VenueTicket
};

use blast_fun::{
    allocation,
    blast_fun::{Self as package_version, BLAST_FUN},
    creator_authority::{Self, CurveFeeCap},
    launch::{Self, Launch, LaunchRegistry},
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    runtime_config::{Self, RuntimeConfig}
};

use blast_fun_migrators::{
    blast_fun_migrators::{Self as migrators_version, PackageVersion as MigratorsVersion},
    venue_config::{Self, VenueConfig}
};

use blast_partners::blast_partners::{Self, Partner};

use blast_vault::{
    blast_vault_package::{Self, BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::Vault
};

use std::unit_test::destroy;

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::Currency,
    test_scenario::{Self, Scenario}
};
