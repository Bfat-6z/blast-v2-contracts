// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::migration_tests;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

public struct VenueWitness() has drop;

public struct OtherVenueWitness() has drop;

public struct TestPackageWitness() has drop;

public struct OtherPackageWitness() has drop;

// === Tests ===

#[test]
fun a_ticket_names_its_venue() {
    let venue = migration::issue_ticket<MEME, QUOTE, _>(VenueWitness()).redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<VenueWitness>());
}

#[test]
fun the_stored_venue_redeems_the_balances_and_terms() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, terms) = migration.redeem(VenueWitness());

    assert_eq!(meme.value(), 100);
    assert_eq!(quote.value(), 200);
    assert_eq!(terms.origin(), sale_id());
    assert_eq!(terms.package_witness(), type_name::with_original_ids<TestPackageWitness>());
    let (meme_share, quote_share) = terms.protocol_bps();
    assert_eq!(vector[meme_share, quote_share], vector[bps::new(1_500), bps::new(1_000)]);
    assert_eq!(terms.partner_id(), option::none());
    assert!(terms.has_protocol_residuals());
    assert!(terms.fee_split().routes()[0].destination().is_owner());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun another_venue_cannot_redeem_the_migration() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, _) = migration.redeem(OtherVenueWitness());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongPackageWitness,
    location = blast_core::migration,
)]
fun a_package_cannot_migrate_with_another_packages_terms() {
    let migration = migration::new(
        OtherPackageWitness(),
        balance::create_for_testing<MEME>(1),
        balance::create_for_testing<QUOTE>(1),
        type_name::with_original_ids<VenueWitness>(),
        sale_terms(),
    );

    destroy(migration);
}

#[test]
/// A standalone issuer seals terms without a hand-off and issues the owner proofs for them.
fun standalone_terms_verify_owner_proofs_from_their_issuer() {
    let terms = migration::vault_terms(
        OtherPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(0),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
    assert!(!terms.has_protocol_residuals());

    owner_proof::new(OtherPackageWitness(), sale_id()).assert_terms(&terms);
}

#[test]
fun the_sale_owner_proof_verifies_against_its_vault_terms() {
    let terms = sale_terms();

    owner_proof::new(TestPackageWitness(), sale_id()).assert_terms(&terms);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_package_cannot_prove_ownership() {
    owner_proof::new(OtherPackageWitness(), sale_id()).assert_terms(&sale_terms());
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_sale_cannot_prove_ownership() {
    let other_sale = object::id_from_address(@0xB0B);
    owner_proof::new(TestPackageWitness(), other_sale).assert_terms(&sale_terms());
}

#[test]
fun terms_at_the_lp_fee_maximum_are_sealed() {
    let terms = migration::vault_terms(
        TestPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(constants::max_lp_fee_bps!()),
        bps::new(constants::max_lp_fee_bps!()),
        option::none(),
        migration::residuals_to_owner(),
    );
    let (meme_share, quote_share) = terms.protocol_bps();

    assert_eq!(vector[meme_share.value(), quote_share.value()], vector[3_000, 3_000]);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidLpFeeBps, location = blast_core::migration)]
fun terms_reject_a_meme_share_above_the_lp_fee_maximum() {
    migration::vault_terms(
        TestPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(3_001),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidLpFeeBps, location = blast_core::migration)]
fun terms_reject_a_quote_share_above_the_lp_fee_maximum() {
    migration::vault_terms(
        TestPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(0),
        bps::new(3_001),
        option::none(),
        migration::residuals_to_owner(),
    );
}

#[test]
/// The product-free seams: `TestIssuer` seals terms and owner proofs, and `TestVenue` redeems.
fun the_test_issuer_hands_off_to_the_test_venue() {
    let terms = migration::vault_terms(
        migration::test_issuer(),
        sale_id(),
        owner_split(),
        bps::new(1_500),
        bps::new(1_500),
        option::none(),
        migration::residuals_to_owner(),
    );
    owner_proof::new(migration::test_issuer(), sale_id()).assert_terms(&terms);
    let ticket = migration::issue_ticket<MEME, QUOTE, _>(migration::test_venue());
    assert_eq!(ticket.redeem_ticket(), type_name::with_original_ids<migration::TestVenue>());

    let migration = migration::new_for_testing(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(9),
        terms,
    );
    let (meme, quote, redeemed) = migration.redeem(migration::test_venue());

    assert_eq!(vector[meme.value(), quote.value()], vector[7, 9]);
    assert_eq!(redeemed.package_witness(), type_name::with_original_ids<migration::TestIssuer>());
    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun only_the_test_venue_redeems_a_test_migration() {
    let migration = migration::new_for_testing(
        balance::create_for_testing<MEME>(1),
        balance::create_for_testing<QUOTE>(1),
        migration::vault_terms(
            migration::test_issuer(),
            sale_id(),
            owner_split(),
            bps::new(0),
            bps::new(0),
            option::none(),
            migration::residuals_to_owner(),
        ),
    );
    let (meme, quote, _) = migration.redeem(VenueWitness());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongPackageWitness,
    location = blast_core::migration,
)]
fun a_test_migration_needs_terms_the_test_issuer_sealed() {
    destroy(
        migration::new_for_testing(
            balance::create_for_testing<MEME>(1),
            balance::create_for_testing<QUOTE>(1),
            sale_terms(),
        ),
    );
}

// Pool price

#[test]
fun equal_atomic_amounts_price_at_one_in_both_coin_orders() {
    let one_x64 = 1u128 << 64;

    assert_eq!(migration::sqrt_price_x64(1, 1, true), one_x64);
    assert_eq!(migration::sqrt_price_x64(1, 1, false), one_x64);
    let max = std::u64::max_value!();
    assert_eq!(migration::sqrt_price_x64(max, max, true), one_x64);
    assert_eq!(migration::sqrt_price_x64(max, max, false), one_x64);
}

#[test]
/// The atomic-unit vectors of `docs/vectors/quote-decimals.json`, in both coin orders.
fun the_seed_price_matches_the_quote_decimal_vectors() {
    let meme = 200_000_000_000_000_001;
    assert_eq!(migration::sqrt_price_x64(meme, 2_970_000_000_000, true), 71_085_815_383_773_548);
    assert_eq!(
        migration::sqrt_price_x64(meme, 2_970_000_000_000, false),
        4_786_923_594_866_905_679_395,
    );
    assert_eq!(migration::sqrt_price_x64(meme, 2_970_000_000, true), 2_247_930_859_429_608);
    assert_eq!(
        migration::sqrt_price_x64(meme, 2_970_000_000, false),
        151_375_815_449_805_255_005_138,
    );
    assert_eq!(migration::sqrt_price_x64(meme, 297_000_000_000, true), 22_479_308_594_296_080);
    assert_eq!(
        migration::sqrt_price_x64(meme, 297_000_000_000, false),
        15_137_581_544_980_525_500_513,
    );
    assert_eq!(
        migration::sqrt_price_x64(200_000_000_000_000, 2_970_000_000_000, true),
        2_247_930_859_429_608_031,
    );
    assert_eq!(
        migration::sqrt_price_x64(200_000_000_000_000, 2_970_000_000_000, false),
        151_375_815_449_805_254_626,
    );
}

#[test]
fun the_seed_price_rounds_the_square_root_down_in_both_coin_orders() {
    vector[true, false].do!(|meme_is_coin_a| {
        let sqrt_price = migration::sqrt_price_x64(3, 2, meme_is_coin_a);
        let ratio_q128 = if (meme_is_coin_a) (2u256 << 128) / 3 else (3u256 << 128) / 2;

        assert!((sqrt_price as u256) * (sqrt_price as u256) <= ratio_q128);
        assert!(((sqrt_price + 1) as u256) * ((sqrt_price + 1) as u256) > ratio_q128);
    });
}

#[test]
fun the_extreme_amounts_price_at_the_q64_range_ends() {
    let max = std::u64::max_value!();

    // 2^64 * sqrt(1 / max) floors to 2^32, and 2^64 * sqrt(max) to just below 2^96; neither
    // can seed a pool.
    assert_eq!(migration::sqrt_price_x64(max, 1, true), 1 << 32);
    assert_eq!(migration::sqrt_price_x64(1, max, true), 79_228_162_514_264_337_591_396_466_687);
    assert!(!migration::is_seedable_price(1 << 32));
    assert!(!migration::is_seedable_price(79_228_162_514_264_337_591_396_466_687));
    assert_eq!(migration::sqrt_price_x64(0, 1, false), 0);
}

#[test]
fun a_price_is_seedable_exactly_inside_the_halved_tick_range() {
    let min = 4_295_048_016;
    let max = 79_226_673_515_401_279_992_447_579_055;

    assert!(migration::is_seedable_price(min * 2));
    assert!(!migration::is_seedable_price(min * 2 - 1));
    assert!(migration::is_seedable_price(max / 2));
    assert!(!migration::is_seedable_price(max / 2 + 1));
    assert!(migration::is_seedable_price(1 << 64));
    assert!(!migration::is_seedable_price(0));
}

#[test]
fun seedability_agrees_for_both_coin_orders() {
    vector[
        vector[1, 1],
        vector[1, 1_000_000_000],
        vector[200_000_000_000_000_001, 2_970_000_000],
        vector[std::u64::max_value!(), 1],
        vector[1, std::u64::max_value!()],
    ].do!(|amounts| {
        assert_eq!(
            migration::is_seedable_price(migration::sqrt_price_x64(amounts[0], amounts[1], true)),
            migration::is_seedable_price(migration::sqrt_price_x64(amounts[0], amounts[1], false)),
        );
    });
}

// === Test Helpers ===

fun sale_id(): ID { object::id_from_address(@0x5A1E) }

fun owner_split(): fee_split::FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

fun sale_terms(): VaultTerms {
    migration::vault_terms(
        TestPackageWitness(),
        sale_id(),
        owner_split(),
        bps::new(1_500),
        bps::new(1_000),
        option::none(),
        migration::residuals_to_protocol(),
    )
}

fun new_migration(venue: type_name::TypeName): Migration<MEME, QUOTE> {
    migration::new(
        TestPackageWitness(),
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(200),
        venue,
        sale_terms(),
    )
}

// === Imports ===

use blast_core::{bps, constants, fee_split, migration::{Self, Migration, VaultTerms}, owner_proof};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::balance;
