// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// A shared fixture for vault and holder-reward tests: an unpaused version, a registry with the
/// test venue and test sale witness admitted, the treasury, a partner, a burn-only or fixed-supply
/// Meme currency with minted supply, and sale terms sealed by a test package witness.
module blast_vault::vault_fixture;

// === Constants ===

const SENDER: address = @0x5E4D;
const TREASURY: address = @0x7EA5;
const PARTNER_RECIPIENT: address = @0xBA27;
const POOL: address = @0x9001;
const SALE: address = @0x5A1E;
const MEME_SUPPLY: u64 = 1_000_000_000_000;

// === Test-Only Types ===

public struct VAULT_FIXTURE() has drop;

public struct QUOTE() has drop;

/// The admitted test venue's witness.
public struct TestVenue() has drop;

/// A venue that was never admitted.
public struct OtherVenue() has drop;

/// The sale package witness that seals the test terms and owner proofs.
public struct SaleWitness() has drop;

/// A package witness that was never admitted as an issuer.
public struct StrangerIssuer() has drop;

/// A stand-in for a venue's position object.
public struct TestPosition has key, store {
    id: UID,
}

public struct VaultFixture {
    registry: VaultRegistry,
    version: PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: Treasury,
    partner: Partner,
    currency: Currency<VAULT_FIXTURE>,
    meme_supply: Balance<VAULT_FIXTURE>,
    clock: Clock,
}

// === Test Helpers ===

/// Begins a scenario as the fixture's sender.
public fun begin(): Scenario {
    test_scenario::begin(SENDER)
}

/// A fixture whose Meme supply is burn-only.
public fun start(scenario: &mut Scenario): VaultFixture {
    start_with_supply(scenario, true)
}

/// A fixture whose Meme supply is burn-only or fixed.
public fun start_with_supply(scenario: &mut Scenario, burn_only: bool): VaultFixture {
    let ctx = scenario.ctx();
    let (initializer, mut treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<VAULT_FIXTURE>(),
        9,
        b"TEST".to_string(),
        b"Vault fixture".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);
    let meme_supply = treasury_cap.mint(MEME_SUPPLY, ctx).into_balance();
    if (burn_only) currency.make_supply_burn_only(treasury_cap)
    else currency.make_supply_fixed(treasury_cap);

    VaultFixture {
        registry: blast_vault_package::registry_for_testing<TestVenue, SaleWitness>(ctx),
        version: blast_vault_package::version_for_testing(ctx),
        treasury: blast_treasury::new_for_testing(TREASURY, ctx),
        partner: blast_partners::new_for_testing(PARTNER_RECIPIENT, 3_000, ctx),
        currency,
        meme_supply,
        clock: clock::create_for_testing(ctx),
    }
}

/// Destroys every fixture object.
public fun end(self: VaultFixture) {
    let VaultFixture { registry, version, treasury, partner, currency, meme_supply, clock } = self;
    destroy(registry);
    destroy(version);
    destroy(treasury);
    destroy(partner);
    destroy(currency);
    destroy(meme_supply);
    clock.destroy_for_testing();
}

/// The admitted test venue's witness.
public fun venue(): TestVenue { TestVenue() }

/// A venue witness that was never admitted.
public fun other_venue(): OtherVenue { OtherVenue() }

/// The test sale's package witness.
public fun sale_witness(): SaleWitness { SaleWitness() }

/// A package witness that was never admitted.
public fun stranger_issuer(): StrangerIssuer { StrangerIssuer() }

public fun sender(): address { SENDER }

public fun treasury_address(): address { TREASURY }

public fun partner_recipient(): address { PARTNER_RECIPIENT }

public fun sale_id(): ID { object::id_from_address(SALE) }

public fun pool_id(): ID { object::id_from_address(POOL) }

/// A fee split paying everything to the owner.
public fun owner_split(): FeeSplit {
    single_route_split(fee_split::owner_destination())
}

/// A fee split paying everything to `destination`.
public fun single_route_split(destination: Destination): FeeSplit {
    fee_split::new(vector[fee_split::route(destination, bps::new(10_000))])
}

/// Terms sealed by the test sale for `fee_split` and Blast's shares, optionally naming the
/// fixture's partner and sending residuals to the protocol.
public fun terms_for(
    self: &VaultFixture,
    fee_split: FeeSplit,
    meme_bps: u64,
    quote_bps: u64,
    names_partner: bool,
    residuals_to_protocol: bool,
): VaultTerms {
    migration::vault_terms(
        SaleWitness(),
        sale_id(),
        fee_split,
        bps::new(meme_bps),
        bps::new(quote_bps),
        if (names_partner) option::some(object::id(&self.partner)) else option::none(),
        if (residuals_to_protocol) migration::residuals_to_protocol()
        else migration::residuals_to_owner(),
    )
}

/// Terms for `fee_split` at Blast's 15% share, sealed by `issuer` for the test sale's ID.
public fun terms_sealed_by<Issuer: drop>(issuer: Issuer, fee_split: FeeSplit): VaultTerms {
    migration::vault_terms(
        issuer,
        sale_id(),
        fee_split,
        bps::new(1_500),
        bps::new(1_500),
        option::none(),
        migration::residuals_to_owner(),
    )
}

/// An owner proof for the test sale.
public fun owner_proof(): OwnerProof {
    owner_proof::new(SaleWitness(), sale_id())
}

/// A fresh stand-in position.
public fun new_position(ctx: &mut TxContext): TestPosition {
    TestPosition { id: object::new(ctx) }
}

/// Builds and shares a vault for `terms` with one unit of liquidity and the given residuals, then
/// moves to the next transaction.
public fun share_vault(
    self: &mut VaultFixture,
    scenario: &mut Scenario,
    terms: VaultTerms,
    residual_meme: u64,
    residual_quote: u64,
) {
    let vault = self.new_vault(terms);
    let residual_meme = self.meme(residual_meme);
    vault.share_with_position(
        &TestVenue(),
        &self.treasury,
        new_position(scenario.ctx()),
        1,
        residual_meme,
        balance::create_for_testing<QUOTE>(residual_quote),
        scenario.ctx(),
    );
    scenario.next_tx(SENDER);
}

/// Builds an unshared vault for `terms` through the admitted test venue.
public fun new_vault(self: &mut VaultFixture, terms: VaultTerms): Vault<VAULT_FIXTURE, QUOTE> {
    self.new_vault_through(&TestVenue(), terms)
}

/// Builds an unshared vault for `terms` through `venue`.
public fun new_vault_through<Venue>(
    self: &mut VaultFixture,
    venue: &Venue,
    terms: VaultTerms,
): Vault<VAULT_FIXTURE, QUOTE> {
    vault::new(&mut self.registry, venue, &self.version, terms, pool_id())
}

/// The ID the registry derives for the vault of terms sealed by `Issuer` for the sale `origin`.
public fun derived_vault_id<Issuer>(self: &VaultFixture, origin: ID): ID {
    let key = vault::vault_key_for_testing(type_name::with_original_ids<Issuer>(), origin);
    object::id_from_address(derived_object::derive_address(object::id(&self.registry), key))
}

/// Takes the shared vault.
public fun take_vault(scenario: &Scenario): Vault<VAULT_FIXTURE, QUOTE> {
    scenario.take_shared<Vault<VAULT_FIXTURE, QUOTE>>()
}

/// Splits `amount` of minted Meme supply.
public fun meme(self: &mut VaultFixture, amount: u64): Balance<VAULT_FIXTURE> {
    self.meme_supply.split(amount)
}

/// Splits one collection of `meme` and `quote` through the admitted test venue.
public fun collect(
    self: &mut VaultFixture,
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
    meme: u64,
    quote: u64,
    ctx: &mut TxContext,
) {
    self.collect_through(vault, &TestVenue(), meme, quote, ctx);
}

/// Splits one collection of `meme` and `quote` through `venue`.
public fun collect_through<Venue>(
    self: &mut VaultFixture,
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
    venue: &Venue,
    meme: u64,
    quote: u64,
    ctx: &mut TxContext,
) {
    let meme_fee = self.meme(meme);
    vault.split_fees(
        venue,
        &self.version,
        &self.treasury,
        &mut self.currency,
        meme_fee,
        balance::create_for_testing<QUOTE>(quote),
        ctx,
    );
}

/// Burns `meme_out` of bought Meme for the buyback `receipt` records, returning `unspent_quote`.
public fun burn_buyback(
    self: &mut VaultFixture,
    vault: &mut Vault<VAULT_FIXTURE, QUOTE>,
    receipt: BuybackReceipt,
    meme_out: u64,
    unspent_quote: u64,
    min_meme_out: u64,
    ctx: &mut TxContext,
) {
    let meme = self.meme(meme_out);
    vault.burn_buyback(
        &TestVenue(),
        &self.version,
        receipt,
        &mut self.currency,
        meme,
        balance::create_for_testing<QUOTE>(unspent_quote),
        min_meme_out,
        ctx,
    );
}

/// Moves the treasury to `destination` through its full delay, advancing the fixture clock.
public fun change_treasury(self: &mut VaultFixture, destination: address) {
    let delay_ms = 48 * 60 * 60 * 1_000;
    let treasury_admin: AdminWitness<TreasuryAdmin> = blast_acl::witness_for_testing();
    self.treasury.schedule_destination(&treasury_admin, destination, delay_ms, &self.clock);
    self.clock.increment_for_testing(delay_ms);
    self.treasury.apply_destination(&self.clock);
}

/// Takes the most recent coin of `Asset` sent to `owner`, returning its value and destroying it.
public fun take_coin_value<Asset>(scenario: &Scenario, owner: address): u64 {
    let coin = scenario.take_from_address<Coin<Asset>>(owner);
    let value = coin.value();
    destroy(coin);

    value
}

/// Whether `owner` received a coin of `Asset` in an earlier transaction.
public fun has_coin<Asset>(owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<Asset>>(owner)
}

/// The Meme currency's total supply.
public fun meme_total_supply(self: &VaultFixture): u64 {
    self.currency.total_supply().destroy_some()
}

public fun registry(self: &VaultFixture): &VaultRegistry { &self.registry }

public fun registry_mut(self: &mut VaultFixture): &mut VaultRegistry { &mut self.registry }

public fun version(self: &VaultFixture): &PackageVersion<BLAST_VAULT_PACKAGE> { &self.version }

public fun version_mut(self: &mut VaultFixture): &mut PackageVersion<BLAST_VAULT_PACKAGE> {
    &mut self.version
}

public fun treasury(self: &VaultFixture): &Treasury { &self.treasury }

public fun treasury_mut(self: &mut VaultFixture): &mut Treasury { &mut self.treasury }

public fun partner(self: &VaultFixture): &Partner { &self.partner }

public fun clock(self: &VaultFixture): &Clock { &self.clock }

public fun clock_mut(self: &mut VaultFixture): &mut Clock { &mut self.clock }

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, package_version::PackageVersion};

use blast_core::{
    blast_domain::TreasuryAdmin,
    blast_treasury::{Self, Treasury},
    bps,
    fee_split::{Self, Destination, FeeSplit},
    migration::{Self, VaultTerms},
    owner_proof::{Self, OwnerProof}
};

use blast_partners::blast_partners::{Self, Partner};

use blast_vault::{
    blast_vault_package::{Self, BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, BuybackReceipt, Vault}
};

use std::{type_name, unit_test::destroy};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::Coin,
    coin_registry::{Self, Currency},
    derived_object,
    test_scenario::{Self, Scenario},
    test_utils
};
