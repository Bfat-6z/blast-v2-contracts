// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The vendor venue over `blast_core`: publication, the ticket and pool creation `prepare`
/// reserves, the hand-off only this venue redeems, and the migration postconditions. The
/// Aftermath interfaces are `abort 0` link stubs, so a migration that reaches pool creation aborts
/// there; the deployment runbook proves the live pool path by dev-inspect.
module blast_aftermath_dao_presale::blast_aftermath_dao_presale_tests;

// === Test-Only Types ===

public struct SALE() has drop;

public struct QUOTE() has drop;

/// The fresh Aftermath LP coin a sale token's pool creation is reserved for.
public struct LP() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// Publication sends the only AdminCap to the publisher.
fun publication_sends_the_admin_cap_to_the_publisher() {
    let mut scenario = publish();

    assert!(test_scenario::has_most_recent_for_address<AdminCap>(PUBLISHER));
    scenario.next_tx(KEEPER);
    assert!(!test_scenario::has_most_recent_for_address<AdminCap>(KEEPER));
    scenario.end();
}

#[test]
/// `prepare` issues this venue's ticket for the pair and shares one pool creation for the sale
/// token and LP coin, bound to the issuer and recorded in one event.
fun prepare_issues_this_venues_ticket_and_shares_the_pool_creation() {
    let mut scenario = publish();

    let venue = scenario.prepare().redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<Venue>());
    let reserved = event::events_by_type<PoolCreationReserved<LP, SALE, QUOTE>>();
    scenario.next_tx(KEEPER);
    let pool_creation = scenario.take_shared<PoolCreation<LP, SALE>>();
    assert_eq!(
        reserved,
        vector[
            migrator::pool_creation_reserved_for_testing(
                object::id(&pool_creation),
                type_name::with_original_ids<TestIssuer>(),
            ),
        ],
    );
    test_scenario::return_shared(pool_creation);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0, location = amm::pool_factory)]
/// A sale's migration consumes its pool creation and redeems the hand-off under this venue,
/// reaching Aftermath's pool creation, where the link stub aborts.
fun migrate_redeems_the_hand_off_before_pool_creation() {
    let mut scenario = publish();
    scenario.prepare().redeem_ticket();

    scenario.next_tx(KEEPER);
    scenario.migrate(type_name::with_original_ids<Venue>());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongVenue,
    location = blast_core::migration,
)]
/// A hand-off sealed for another venue never reaches Aftermath.
fun migrate_refuses_a_hand_off_for_another_venue() {
    let mut scenario = publish();
    scenario.prepare().redeem_ticket();

    scenario.next_tx(KEEPER);
    scenario.migrate(type_name::with_original_ids<QUOTE>());

    abort
}

#[test]
#[expected_failure(abort_code = migrator::EWrongPackageWitness, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
/// A hand-off for this venue whose terms another package sealed cannot consume the pool creation
/// the AdminCap bound to the presale's issuer, so it can never set the sale's pool price.
fun migrate_refuses_terms_another_issuer_sealed() {
    let mut scenario = publish();
    scenario.prepare_for<A>().redeem_ticket();

    scenario.next_tx(KEEPER);
    scenario.migrate(type_name::with_original_ids<Venue>());

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
/// The venue check precedes the issuer check.
fun migrate_checks_the_venue_before_the_issuer() {
    let mut scenario = publish();
    scenario.prepare_for<A>().redeem_ticket();

    scenario.next_tx(KEEPER);
    scenario.migrate(type_name::with_original_ids<QUOTE>());

    abort
}

#[test]
#[expected_failure(abort_code = migrator::EInvalidPackageWitness, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
/// Anyone can construct a primitive, so it cannot be the issuer.
fun prepare_rejects_a_primitive_issuer() {
    let mut scenario = publish();

    scenario.prepare_for<u64>().redeem_ticket();

    abort
}

#[test]
#[expected_failure(abort_code = migrator::EInvalidPackageWitness, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
/// Anyone can construct a framework type such as `SUI`'s witness, so it cannot be the issuer.
fun prepare_rejects_a_framework_issuer() {
    let mut scenario = publish();

    scenario.prepare_for<SUI>().redeem_ticket();

    abort
}

#[test]
#[expected_failure(abort_code = migrator::EInvalidPackageWitness, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
/// Standard-library types are refused like framework types.
fun prepare_rejects_a_standard_library_issuer() {
    let mut scenario = publish();

    scenario.prepare_for<String>().redeem_ticket();

    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // The standard library's 0x1 sorts before the framework's 0x2, whatever address this
    // package builds at: under `--build-env mainnet` it is the published address, not 0x0.
    assert!(sorts_before_for_testing<String, SUI>());
    assert!(!sorts_before_for_testing<SUI, String>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

#[test]
fun migration_postconditions_accept_exact_balances_fee_and_recipient() {
    migrator::assert_pool_balances_for_testing(100, 100, 200, 200);
    migrator::assert_dao_fee_terms_for_testing(200, 200, @0xA, @0xA);
}

#[test]
#[expected_failure(abort_code = migrator::EPoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun migration_rejects_wrong_meme_balance() {
    migrator::assert_pool_balances_for_testing(99, 100, 200, 200);
}

#[test]
#[expected_failure(abort_code = migrator::EPoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun migration_rejects_wrong_quote_balance() {
    migrator::assert_pool_balances_for_testing(100, 100, 199, 200);
}

#[test]
#[expected_failure(abort_code = migrator::EDaoFeePoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun migration_rejects_wrong_dao_fee() {
    migrator::assert_dao_fee_terms_for_testing(199, 200, @0xA, @0xA);
}

#[test]
#[expected_failure(abort_code = migrator::EDaoFeePoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun migration_rejects_wrong_dao_fee_recipient() {
    migrator::assert_dao_fee_terms_for_testing(200, 200, @0xB, @0xA);
}

#[test]
#[expected_failure(abort_code = migrator::EPoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun meme_mismatch_rejects_before_reading_quote() {
    migrator::assert_pool_short_circuit_for_testing();
}

#[test]
#[expected_failure(abort_code = migrator::EDaoFeePoolMismatch, location = blast_aftermath_dao_presale::blast_aftermath_dao_presale)]
fun fee_mismatch_rejects_before_reading_recipient() {
    migrator::assert_dao_fee_short_circuit_for_testing();
}

// === Test Helpers ===

/// Runs `init`, then opens the publisher's next transaction.
fun publish(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    migrator::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    scenario
}

/// The publisher's AdminCap prepares `SALE` in `QUOTE` with a pool creation reserved for `LP` and
/// the test issuer every hand-off here is sealed by.
fun prepare(scenario: &mut Scenario): VenueTicket<SALE, QUOTE> {
    scenario.prepare_for<TestIssuer>()
}

/// The publisher's AdminCap prepares `SALE` in `QUOTE` with a pool creation reserved for `LP` and
/// bound to `Issuer`.
fun prepare_for<PackageWitness>(scenario: &mut Scenario): VenueTicket<SALE, QUOTE> {
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let create_pool_cap = amm_pool::create_pool_cap_for_testing(scenario.ctx());

    let ticket = migrator::prepare<LP, SALE, QUOTE, PackageWitness>(&admin_cap, create_pool_cap, scenario.ctx());

    scenario.return_to_sender(admin_cap);
    ticket
}

/// Migrates the prepared sale with a test issuer's hand-off sealed for `venue`.
fun migrate(scenario: &mut Scenario, venue: TypeName) {
    let pool_creation = scenario.take_shared<PoolCreation<LP, SALE>>();
    let origin = object::new(scenario.ctx());
    let terms = migration::vault_terms(
        migration::test_issuer(),
        &origin,
        fee_split::new(vector[
            fee_split::route(fee_split::owner_destination(), bps::new(10_000)),
        ]),
        bps::new(0),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    let hand_off = migration::new(
        migration::test_issuer(),
        balance::create_for_testing<SALE>(1_000),
        balance::create_for_testing<QUOTE>(2_000),
        venue,
        terms,
    );
    let mut pool_registry = pool_registry::new_for_testing(scenario.ctx());
    let dao_fee_version = version::new_for_testing(scenario.ctx());

    migrator::migrate(
        hand_off,
        pool_creation,
        &mut pool_registry,
        &dao_fee_version,
        scenario.ctx(),
    );

    destroy(pool_registry);
    destroy(dao_fee_version);
}

// === Constants ===

const PUBLISHER: address = @0xB1A57;
const KEEPER: address = @0x4EE9;

// === Imports ===

use amm::{pool as amm_pool, pool_registry};

use blast_aftermath_dao_presale::blast_aftermath_dao_presale::{
    Self as migrator,
    AdminCap,
    PoolCreation,
    PoolCreationReserved,
    Venue,
    sorts_before_for_testing,
};

use blast_core::{bps, fee_split, migration::{Self, TestIssuer, VenueTicket}};

use dao_fee_amm::version;

use std::{ascii::String, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{balance, event, sui::SUI, test_scenario::{Self, Scenario}};

use fun migrate as Scenario.migrate;
use fun prepare as Scenario.prepare;
use fun prepare_for as Scenario.prepare_for;
