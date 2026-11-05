// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The single Cetus routes' pair proof and checked retype (ADR 0100), the pool-reservation fact
/// `cetus::prepare` emits, and the venue's vault-registry admission. The routes themselves run against real Cetus bytecode in the PTB
/// venue-fork tests, since the Cetus interfaces are `abort 0` link stubs.
module blast_migrators::cetus_route_tests;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;
public struct OTHER() has drop;

// === Tests ===

#[test]
/// One route serves both Cetus coin orders: it reports which side the Meme is on.
fun the_route_locates_meme_in_either_coin_order() {
    assert!(cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, QUOTE>());
    assert!(!cetus::is_meme_coin_a_for_testing<MEME, QUOTE, QUOTE, MEME>());
}

#[test]
#[expected_failure(abort_code = blast_migrators::errors::EWrongCoinPair, location = blast_migrators::cetus)]
/// A pair that is not exactly the sale's Meme and Quote is rejected before any retype.
fun the_route_rejects_a_foreign_coin_pair() {
    cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, OTHER>();
}

#[test]
#[expected_failure(abort_code = blast_migrators::errors::EWrongCoinPair, location = blast_migrators::cetus)]
/// Naming the Meme on both sides is not the sale's pair either.
fun the_route_rejects_the_same_coin_twice() {
    cetus::is_meme_coin_a_for_testing<MEME, QUOTE, MEME, MEME>();
}

#[test]
/// With Meme as coin A the pair keeps its order; otherwise it swaps, in both directions, and every
/// value arrives intact.
fun a_reorder_maps_either_coin_order_onto_the_other() {
    let mut ctx = tx_context::dummy();

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<MEME>, Balance<QUOTE>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        true,
        &mut ctx,
    );
    assert_eq!(coin_a.destroy_for_testing(), 7);
    assert_eq!(coin_b.destroy_for_testing(), 11);

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<QUOTE>, Balance<MEME>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        false,
        &mut ctx,
    );
    assert_eq!(coin_a.destroy_for_testing(), 11);
    assert_eq!(coin_b.destroy_for_testing(), 7);

    let (meme, quote) = cetus::reorder_for_testing<_, _, Balance<MEME>, Balance<QUOTE>>(
        balance::create_for_testing<QUOTE>(11),
        balance::create_for_testing<MEME>(7),
        false,
        &mut ctx,
    );
    assert_eq!(meme.destroy_for_testing(), 7);
    assert_eq!(quote.destroy_for_testing(), 11);
}

#[test]
#[expected_failure(abort_code = sui::dynamic_field::EFieldTypeMismatch, location = sui::dynamic_field)]
/// The framework refuses to hand a stored balance back under any other type.
fun a_reorder_to_another_type_aborts_in_the_framework() {
    let mut ctx = tx_context::dummy();

    let (coin_a, coin_b) = cetus::reorder_for_testing<_, _, Balance<QUOTE>, Balance<MEME>>(
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(11),
        true,
        &mut ctx,
    );
    destroy(coin_a);
    destroy(coin_b);
    abort
}

#[test]
/// The reservation is typed by the pair and names the reserved capability and the tick spacing the
/// migration will use.
fun the_pool_reservation_records_the_pair_the_capability_and_the_tick_spacing() {
    let pool_creation_cap_id = @0xCA9.to_id();

    events::cetus_pool_reserved<MEME, QUOTE>(pool_creation_cap_id, 60);

    assert_eq!(
        event::events_by_type<CetusPoolReserved<MEME, QUOTE>>(),
        vector[events::cetus_pool_reserved_for_testing(pool_creation_cap_id, 60)],
    );
}

#[test]
/// The vault registry admits the Cetus venue's witness at its publication notice of zero.
fun the_vault_registry_admits_the_cetus_venue() {
    let mut ctx = tx_context::dummy();
    let mut registry = blast_vault_package::empty_registry_for_testing(&mut ctx);
    let vault_version = blast_vault_package::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();

    registry.schedule_witness<Venue>(&admin, &vault_version, &clock);
    registry.apply_witness<Venue>(&vault_version, &clock);

    let admitted = event::events_by_type<SetApplied<WitnessesKey, TypeName>>().map!(|applied| {
        let (_, _, change, _) = applied.set_applied_fields();
        change.member().destroy_some()
    });
    assert_eq!(admitted, vector[type_name::with_original_ids<Venue>()]);
    destroy(registry);
    destroy(vault_version);
    clock.destroy_for_testing();
}

// === Imports ===

use blast_admin::{blast_acl, delayed_set::SetApplied};

use blast_core::blast_domain::AdapterAdmin;

use blast_migrators::{cetus::{Self, Venue}, events::{Self, CetusPoolReserved}};

use blast_vault::blast_vault_package::{Self, WitnessesKey};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{balance::{Self, Balance}, clock, event};
