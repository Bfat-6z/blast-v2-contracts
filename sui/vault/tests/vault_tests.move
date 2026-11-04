// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_vault::vault_tests;

// === Constants ===

const ROUTE_RECIPIENT: address = @0xAD;
const NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

// === Tests ===

// Creation and residuals

#[test]
fun owner_residuals_wait_for_the_owner() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 5, 7);

    let vault = vault_fixture::take_vault(&scenario);
    let (owner_meme, owner_quote, _, _, _, _, _) = vault.balances_for_testing();
    assert!(owner_meme == 5 && owner_quote == 7);
    let (protocol_meme, protocol_quote, _) = vault.protocol_balances_for_testing();
    assert!(protocol_meme == 0 && protocol_quote == 0);
    assert_eq!(vault.pool_id(), vault_fixture::pool_id());

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun creation_emits_one_event_in_its_own_transaction() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    let vault = f.new_vault(terms);
    let position = vault_fixture::new_position(scenario.ctx());
    vault.share_with_position(
        &vault_fixture::venue(),
        f.treasury(),
        position,
        1,
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );

    assert_eq!(event::events_by_type<VaultCreated<VAULT_FIXTURE, QUOTE, TestVenue>>().length(), 1);

    f.end();
    scenario.end();
}

#[test]
fun protocol_residuals_without_a_partner_are_paid_to_the_treasury_at_creation() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, true);
    f.share_vault(&mut scenario, terms, 10, 20);

    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, vault_fixture::treasury_address()), 10);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, vault_fixture::treasury_address()), 20);
    let vault = vault_fixture::take_vault(&scenario);
    let (protocol_meme, protocol_quote, _) = vault.protocol_balances_for_testing();
    assert!(protocol_meme == 0 && protocol_quote == 0);

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun protocol_residuals_with_a_partner_are_held_then_paid_with_its_cut() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, true, true);
    f.share_vault(&mut scenario, terms, 1_000, 100);

    let mut vault = vault_fixture::take_vault(&scenario);
    let (protocol_meme, protocol_quote, _) = vault.protocol_balances_for_testing();
    assert!(protocol_meme == 1_000 && protocol_quote == 100);
    vault.pay_protocol_fees_with_partner(f.version(), f.treasury(), f.partner(), scenario.ctx());
    test_scenario::return_shared(vault);
    scenario.next_tx(vault_fixture::sender());

    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, vault_fixture::partner_recipient()), 300);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, vault_fixture::partner_recipient()), 30);
    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, vault_fixture::treasury_address()), 700);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, vault_fixture::treasury_address()), 70);

    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedVenue,
    location = blast_vault::blast_vault_package,
)]
fun an_unadmitted_venue_cannot_create_a_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);

    let vault = f.new_vault_through(&vault_fixture::other_venue(), terms);

    destroy(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidProtocolBps,
    location = blast_vault::vault,
)]
fun terms_above_the_blast_share_maximum_cannot_create_a_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 3_001, false, false);

    destroy(f.new_vault(terms));
    f.end();
    scenario.end();
}

#[test]
fun terms_at_the_blast_share_maximum_create_a_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 3_000, 3_000, false, false);

    let vault = f.new_vault(terms);
    let (meme_bps, quote_bps) = vault.protocol_bps_for_testing();
    assert!(meme_bps.value() == 3_000 && quote_bps.value() == 3_000);

    destroy(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedIssuer,
    location = blast_vault::blast_vault_package,
)]
fun terms_sealed_by_an_unadmitted_issuer_cannot_create_a_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = vault_fixture::terms_sealed_by(vault_fixture::stranger_issuer(), owner_split());

    destroy(f.new_vault(terms));
    f.end();
    scenario.end();
}

#[test]
fun an_admitted_venue_seals_its_own_standalone_terms() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = vault_fixture::terms_sealed_by(vault_fixture::venue(), owner_split());

    destroy(f.new_vault(terms));
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedIssuer,
    location = blast_vault::blast_vault_package,
)]
fun a_removed_issuer_cannot_create_vaults_for_its_sales() {
    let mut scenario = vault_fixture::begin();
    let f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    let mut registry = blast_vault_package::registry_for_testing<TestVenue, SaleWitness>(
        scenario.ctx(),
    );
    registry.remove_witness<SaleWitness>(&adapter_admin(), f.version());

    destroy(
        vault::new<VAULT_FIXTURE, QUOTE, _>(
            &mut registry,
            &vault_fixture::venue(),
            f.version(),
            terms,
            vault_fixture::pool_id(),
        ),
    );
    destroy(registry);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedVenue,
    location = blast_vault::blast_vault_package,
)]
fun an_unadmitted_venue_is_reported_before_an_unadmitted_issuer() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = vault_fixture::terms_sealed_by(vault_fixture::stranger_issuer(), owner_split());

    destroy(f.new_vault_through(&vault_fixture::other_venue(), terms));
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EUnadmittedIssuer,
    location = blast_vault::blast_vault_package,
)]
fun an_unadmitted_issuer_is_reported_before_the_blast_share_maximum() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = migration::vault_terms(
        vault_fixture::stranger_issuer(),
        vault_fixture::sale_id(),
        owner_split(),
        bps::new(3_001),
        bps::new(3_001),
        option::none(),
        migration::residuals_to_owner(),
    );

    destroy(f.new_vault(terms));
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EZeroLiquidity, location = blast_vault::vault)]
fun a_position_without_liquidity_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    let vault = f.new_vault(terms);
    let position = vault_fixture::new_position(scenario.ctx());

    vault.share_with_position(
        &vault_fixture::venue(),
        f.treasury(),
        position,
        0,
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );

    f.end();
    scenario.end();
}

// Derived identity

#[test]
fun a_vault_id_derives_from_the_registry_the_sealing_issuer_and_the_sale() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);

    let vault = f.new_vault(terms);

    assert_eq!(object::id(&vault), f.derived_vault_id<SaleWitness>(vault_fixture::sale_id()));
    destroy(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = sui::derived_object::EObjectAlreadyExists, location = sui::derived_object)]
fun a_second_vault_for_the_same_issuer_and_sale_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let first_terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    let second_terms = f.terms_for(owner_split(), 0, 0, false, false);
    let first = f.new_vault(first_terms);

    let second = f.new_vault(second_terms);

    destroy(first);
    destroy(second);
    f.end();
    scenario.end();
}

#[test]
fun the_same_sale_under_another_issuer_gets_another_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let sale_terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    let venue_terms = vault_fixture::terms_sealed_by(vault_fixture::venue(), owner_split());
    let sale_vault = f.new_vault(sale_terms);

    let venue_vault = f.new_vault(venue_terms);

    assert_eq!(object::id(&venue_vault), f.derived_vault_id<TestVenue>(vault_fixture::sale_id()));
    assert!(object::id(&venue_vault) != object::id(&sale_vault));
    destroy(sale_vault);
    destroy(venue_vault);
    f.end();
    scenario.end();
}

// Fee collection

#[test]
/// 15% for Blast rounds up; the rest splits 40/20/20/10/10 by largest remainder.
fun a_collection_pays_blast_rounded_up_then_every_route_exactly() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(every_route_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 1_001, 2_003, scenario.ctx());
    let (owner_meme, owner_quote, auto_lp_meme, auto_lp_quote, rewards_meme, rewards_quote, burn_quote) =
        vault.balances_for_testing();
    assert!(owner_meme == 340 && owner_quote == 681);
    assert!(auto_lp_meme == 170 && auto_lp_quote == 341);
    assert!(rewards_meme == 170 && rewards_quote == 340);
    assert_eq!(burn_quote, 170);
    test_scenario::return_shared(vault);
    scenario.next_tx(vault_fixture::sender());

    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, ROUTE_RECIPIENT), 85);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, ROUTE_RECIPIENT), 170);
    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, vault_fixture::treasury_address()), 151);
    assert_eq!(vault_fixture::take_coin_value<QUOTE>(&scenario, vault_fixture::treasury_address()), 301);

    f.end();
    scenario.end();
}

#[test]
fun a_burn_only_supply_burns_the_burn_routes_meme() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let burn_split = fee_split::new(vector[
        fee_split::route(fee_split::burn_destination(), bps::new(10_000)),
    ]);
    let terms = f.terms_for(burn_split, 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let supply_before = f.meme_total_supply();

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 40, 10, scenario.ctx());
    let (_, _, _, _, _, _, burn_quote) = vault.balances_for_testing();
    assert_eq!(burn_quote, 10);
    assert_eq!(f.meme_total_supply(), supply_before - 40);

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun a_fixed_supply_sends_the_burn_routes_meme_to_the_zero_address() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start_with_supply(&mut scenario, false);
    let burn_split = fee_split::new(vector[
        fee_split::route(fee_split::burn_destination(), bps::new(10_000)),
    ]);
    let terms = f.terms_for(burn_split, 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 40, 0, scenario.ctx());
    test_scenario::return_shared(vault);
    scenario.next_tx(vault_fixture::sender());

    assert_eq!(vault_fixture::take_coin_value<VAULT_FIXTURE>(&scenario, @0x0), 40);

    f.end();
    scenario.end();
}

#[test]
fun a_zero_collection_moves_and_emits_nothing() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 0, 0, scenario.ctx());
    assert_eq!(event::events_by_type<FeesCollected<VAULT_FIXTURE, QUOTE>>().length(), 0);
    assert_eq!(event::events_by_type<ProtocolFeesPaid<VAULT_FIXTURE, QUOTE>>().length(), 0);

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun a_partnered_collection_holds_blasts_cut_for_the_partner_payout() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, true, false);
    f.share_vault(&mut scenario, terms, 0, 0);

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 1_000, 1_000, scenario.ctx());
    let (protocol_meme, protocol_quote, _) = vault.protocol_balances_for_testing();
    assert!(protocol_meme == 150 && protocol_quote == 150);
    test_scenario::return_shared(vault);
    scenario.next_tx(vault_fixture::sender());

    assert!(!vault_fixture::has_coin<VAULT_FIXTURE>(vault_fixture::treasury_address()));

    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVenue, location = blast_vault::vault)]
fun another_venue_cannot_split_the_vaults_fees() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);

    f.collect_through(&mut vault, &vault_fixture::other_venue(), 10, 10, scenario.ctx());

    abort
}

// Owner

#[test]
fun the_owner_claims_its_fees_and_residuals_together() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 5, 7);

    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 100, 200, scenario.ctx());
    let (meme, quote) = vault.claim_owner_balances(vault_fixture::owner_proof(), f.version(), scenario.ctx());
    assert!(meme.value() == 105 && quote.value() == 207);
    assert_eq!(event::events_by_type<OwnerBalancesClaimed<VAULT_FIXTURE, QUOTE>>().length(), 1);

    destroy(meme);
    destroy(quote);
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::ENothingToClaim, location = blast_vault::vault)]
fun an_owner_claim_with_nothing_accrued_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);

    let (meme, quote) = vault.claim_owner_balances(vault_fixture::owner_proof(), f.version(), scenario.ctx());

    destroy(meme);
    destroy(quote);
    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongOwner, location = blast_core::owner_proof)]
fun another_sales_proof_cannot_claim() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 5, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let proof = owner_proof::new(vault_fixture::sale_witness(), object::id_from_address(@0xB0B));

    let (meme, quote) = vault.claim_owner_balances(proof, f.version(), scenario.ctx());

    destroy(meme);
    destroy(quote);
    abort
}

#[test]
fun a_fee_split_change_waits_its_notice_and_applies_after_settling() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let rewards_split = fee_split::new(vector[
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(10_000)),
    ]);

    vault.schedule_fee_split(
        vault_fixture::owner_proof(),
        f.version(),
        rewards_split,
        f.clock(),
    );
    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.assert_fee_split_ready(f.clock());
    f.collect(&mut vault, 10, 10, scenario.ctx());
    vault.apply_fee_split(&vault_fixture::venue(), f.version(), f.clock());
    f.collect(&mut vault, 10, 10, scenario.ctx());

    let (owner_meme, _, _, _, rewards_meme, _, _) = vault.balances_for_testing();
    assert!(owner_meme == 10 && rewards_meme == 10);
    assert_eq!(vault.fee_split_for_testing(), rewards_split);

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_fee_split_change_cannot_apply_before_its_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let rewards_split = fee_split::new(vector[
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(10_000)),
    ]);
    vault.schedule_fee_split(
        vault_fixture::owner_proof(),
        f.version(),
        rewards_split,
        f.clock(),
    );

    f.clock_mut().increment_for_testing(NOTICE_MS - 1);
    vault.apply_fee_split(&vault_fixture::venue(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun the_owner_cancels_a_pending_fee_split() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let rewards_split = fee_split::new(vector[
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(10_000)),
    ]);
    vault.schedule_fee_split(
        vault_fixture::owner_proof(),
        f.version(),
        rewards_split,
        f.clock(),
    );
    vault.cancel_fee_split(vault_fixture::owner_proof(), f.version());

    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.apply_fee_split(&vault_fixture::venue(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
/// The notice is fixed: a second fee-split change after an applied one still waits 48 hours.
fun every_fee_split_change_waits_the_full_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let rewards_split = vault_fixture::single_route_split(fee_split::holder_rewards_destination());
    vault.schedule_fee_split(vault_fixture::owner_proof(), f.version(), rewards_split, f.clock());
    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.apply_fee_split(&vault_fixture::venue(), f.version(), f.clock());

    vault.schedule_fee_split(vault_fixture::owner_proof(), f.version(), owner_split(), f.clock());
    f.clock_mut().increment_for_testing(NOTICE_MS - 1);
    vault.apply_fee_split(&vault_fixture::venue(), f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
/// The notice is fixed: a second Blast-share change after an applied one still waits 48 hours.
fun every_blast_share_change_waits_the_full_notice() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.schedule_protocol_bps(&fee_admin(), f.version(), bps::new(2_000), bps::new(2_000), f.clock());
    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.apply_protocol_bps(f.version(), f.clock());

    vault.schedule_protocol_bps(&fee_admin(), f.version(), bps::new(3_000), bps::new(3_000), f.clock());
    f.clock_mut().increment_for_testing(NOTICE_MS - 1);
    vault.apply_protocol_bps(f.version(), f.clock());

    abort
}

// Blast's share

#[test]
fun blasts_share_changes_after_its_notice_and_governs_later_collections() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, true, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);

    vault.schedule_protocol_bps(
        &fee_admin(),
        f.version(),
        bps::new(3_000),
        bps::new(1_000),
        f.clock(),
    );
    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.apply_protocol_bps(f.version(), f.clock());
    f.collect(&mut vault, 1_000, 1_000, scenario.ctx());

    let (protocol_meme, protocol_quote, _) = vault.protocol_balances_for_testing();
    assert!(protocol_meme == 300 && protocol_quote == 100);

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EInvalidProtocolBps,
    location = blast_vault::vault,
)]
fun blasts_share_cannot_be_scheduled_above_the_maximum() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);

    vault.schedule_protocol_bps(
        &fee_admin(),
        f.version(),
        bps::new(3_001),
        bps::new(0),
        f.clock(),
    );

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun a_cancel_administrator_cancels_blasts_pending_share() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.schedule_protocol_bps(
        &fee_admin(),
        f.version(),
        bps::new(2_000),
        bps::new(2_000),
        f.clock(),
    );
    vault.cancel_protocol_bps(&cancel_admin(), f.version());

    f.clock_mut().increment_for_testing(NOTICE_MS);
    vault.apply_protocol_bps(f.version(), f.clock());

    abort
}

// Pause scope

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun the_admin_pause_stops_blasts_share_changes() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    vault.schedule_protocol_bps(
        &fee_admin(),
        f.version(),
        bps::new(2_000),
        bps::new(2_000),
        f.clock(),
    );

    abort
}

#[test]
fun the_admin_pause_never_stops_collection_or_owner_claims() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    f.collect(&mut vault, 10, 10, scenario.ctx());
    let (meme, quote) = vault.claim_owner_balances(vault_fixture::owner_proof(), f.version(), scenario.ctx());
    assert!(meme.value() == 10 && quote.value() == 10);

    destroy(meme);
    destroy(quote);
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

// Buyback and auto-LP

#[test]
fun a_buyback_takes_only_the_requested_quote_burns_the_meme_and_keeps_the_rest() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(100));
    let supply_before = f.meme_total_supply();

    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        60,
    );
    assert_eq!(taken_quote.value(), 60);
    destroy(taken_quote);
    f.burn_buyback(&mut vault, receipt, 50, 10, 40, scenario.ctx());

    let (_, _, _, _, _, _, burn_quote) = vault.balances_for_testing();
    assert_eq!(burn_quote, 50);
    assert_eq!(f.meme_total_supply(), supply_before - 50);
    assert_eq!(
        event::events_by_type<BuybackBurned<VAULT_FIXTURE, QUOTE>>(),
        vector[blast_vault_events::buyback_burned_for_testing(object::id(&vault), 50, 50, 50)],
    );

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EBuybackQuoteOutOfRange,
    location = blast_vault::vault,
)]
fun a_buyback_of_more_than_the_burn_quote_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(100));

    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        101,
    );

    destroy(taken_quote);
    destroy(receipt);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EBuybackBelowMinimum,
    location = blast_vault::vault,
)]
fun a_buyback_below_its_minimum_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(10));
    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );
    destroy(taken_quote);

    f.burn_buyback(&mut vault, receipt, 39, 0, 40, scenario.ctx());

    abort
}

#[test]
fun auto_lp_hands_over_its_balances_and_keeps_what_the_pool_did_not_take() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let auto_lp_split = fee_split::new(vector[
        fee_split::route(fee_split::auto_lp_destination(), bps::new(10_000)),
    ]);
    let terms = f.terms_for(auto_lp_split, 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 30, 40, scenario.ctx());

    let (mut meme, mut quote, receipt) = vault.take_auto_lp(&vault_fixture::venue(), f.version());
    assert!(meme.value() == 30 && quote.value() == 40);
    destroy(meme.split(20));
    destroy(quote.split(40));
    vault.keep_auto_lp(&vault_fixture::venue(), f.version(), receipt, meme, quote);

    let (_, _, auto_lp_meme, auto_lp_quote, _, _, _) = vault.balances_for_testing();
    assert!(auto_lp_meme == 10 && auto_lp_quote == 0);
    assert_eq!(
        event::events_by_type<AutoLiquidityAdded<VAULT_FIXTURE, QUOTE>>(),
        vector[blast_vault_events::auto_liquidity_added_for_testing(object::id(&vault), 20, 40, 10, 0)],
    );

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVault, location = blast_vault::vault)]
fun a_buyback_receipt_from_another_vault_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let (mut vault, mut other_vault) = share_two_vaults(&mut f, &mut scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(10));
    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );
    destroy(taken_quote);

    f.burn_buyback(&mut other_vault, receipt, 0, 11, 1, scenario.ctx());

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EReturnedExceedsTaken,
    location = blast_vault::vault,
)]
fun a_buyback_returning_more_quote_than_it_took_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(10));
    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );
    destroy(taken_quote);

    f.burn_buyback(&mut vault, receipt, 50, 11, 0, scenario.ctx());

    abort
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVault, location = blast_vault::vault)]
fun an_auto_lp_receipt_from_another_vault_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let (mut vault, mut other_vault) = share_two_vaults(&mut f, &mut scenario);
    let (mut meme, quote, receipt) = vault.take_auto_lp(&vault_fixture::venue(), f.version());
    meme.join(f.meme(1));

    other_vault.keep_auto_lp(&vault_fixture::venue(), f.version(), receipt, meme, quote);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EReturnedExceedsTaken,
    location = blast_vault::vault,
)]
fun an_auto_lp_meme_return_above_its_take_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let auto_lp_split = fee_split::new(vector[
        fee_split::route(fee_split::auto_lp_destination(), bps::new(10_000)),
    ]);
    let terms = f.terms_for(auto_lp_split, 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 30, 40, scenario.ctx());
    let (mut meme, quote, receipt) = vault.take_auto_lp(&vault_fixture::venue(), f.version());
    meme.join(f.meme(1));

    vault.keep_auto_lp(&vault_fixture::venue(), f.version(), receipt, meme, quote);

    abort
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EReturnedExceedsTaken,
    location = blast_vault::vault,
)]
fun a_buyback_returning_more_than_it_took_is_reported_before_its_minimum() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(10));
    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );
    destroy(taken_quote);

    f.burn_buyback(&mut vault, receipt, 0, 11, 1, scenario.ctx());

    abort
}

#[test]
fun a_buyback_returning_all_its_quote_spends_none() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(10));
    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );
    destroy(taken_quote);

    f.burn_buyback(&mut vault, receipt, 0, 10, 0, scenario.ctx());

    assert_eq!(
        event::events_by_type<BuybackBurned<VAULT_FIXTURE, QUOTE>>(),
        vector[blast_vault_events::buyback_burned_for_testing(object::id(&vault), 0, 0, 10)],
    );
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = blast_vault::errors::EReturnedExceedsTaken,
    location = blast_vault::vault,
)]
fun an_auto_lp_quote_return_above_its_take_is_rejected() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let auto_lp_split = fee_split::new(vector[
        fee_split::route(fee_split::auto_lp_destination(), bps::new(10_000)),
    ]);
    let terms = f.terms_for(auto_lp_split, 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    f.collect(&mut vault, 30, 40, scenario.ctx());
    let (meme, mut quote, receipt) = vault.take_auto_lp(&vault_fixture::venue(), f.version());
    quote.join(balance::create_for_testing(1));

    vault.keep_auto_lp(&vault_fixture::venue(), f.version(), receipt, meme, quote);

    abort
}

#[test]
fun a_zero_auto_lp_take_keeps_nothing_and_emits_nothing() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);

    let (meme, quote, receipt) = vault.take_auto_lp(&vault_fixture::venue(), f.version());
    assert!(meme.value() == 0 && quote.value() == 0);
    vault.keep_auto_lp(&vault_fixture::venue(), f.version(), receipt, meme, quote);

    assert_eq!(event::events_by_type<AutoLiquidityAdded<VAULT_FIXTURE, QUOTE>>().length(), 0);
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
fun the_auto_lp_position_attaches_once_beside_the_migration_position() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    assert!(!vault.has_auto_lp_position(&vault_fixture::venue()));
    let position = vault_fixture::new_position(scenario.ctx());

    vault.attach_auto_lp_position(&vault_fixture::venue(), f.version(), position);

    assert!(vault.has_auto_lp_position(&vault_fixture::venue()));
    let _: &TestPosition = vault.auto_lp_position(&vault_fixture::venue());
    let _: &mut TestPosition = vault.auto_lp_position_mut(&vault_fixture::venue(), f.version());
    let _: &mut TestPosition = vault.position_mut(&vault_fixture::venue(), f.version());

    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVenue, location = blast_vault::vault)]
fun another_venue_cannot_attach_an_auto_lp_position() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    let position = vault_fixture::new_position(scenario.ctx());

    vault.attach_auto_lp_position(&vault_fixture::other_venue(), f.version(), position);

    abort
}

#[test]
fun the_venue_receives_coins_sent_to_the_vault() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let vault = vault_fixture::take_vault(&scenario);
    let vault_id = object::id(&vault);
    test_scenario::return_shared(vault);
    transfer::public_transfer(coin::mint_for_testing<QUOTE>(25, scenario.ctx()), vault_id.to_address());
    scenario.next_tx(vault_fixture::sender());
    let mut vault = vault_fixture::take_vault(&scenario);

    let received = vault.receive_coin(
        &vault_fixture::venue(),
        f.version(),
        test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&vault_id),
    );

    assert_eq!(received.value(), 25);
    destroy(received);
    test_scenario::return_shared(vault);
    f.end();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_vault::errors::EWrongVenue, location = blast_vault::vault)]
fun another_venue_cannot_receive_the_vaults_coins() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let vault = vault_fixture::take_vault(&scenario);
    let vault_id = object::id(&vault);
    test_scenario::return_shared(vault);
    transfer::public_transfer(coin::mint_for_testing<QUOTE>(25, scenario.ctx()), vault_id.to_address());
    scenario.next_tx(vault_fixture::sender());
    let mut vault = vault_fixture::take_vault(&scenario);

    destroy(
        vault.receive_coin(
            &vault_fixture::other_venue(),
            f.version(),
            test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&vault_id),
        ),
    );

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun the_admin_pause_stops_buybacks() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.fund_burn_quote_for_testing(balance::create_for_testing(100));
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::venue(),
        &buyback_admin(),
        f.version(),
        10,
    );

    destroy(taken_quote);
    destroy(receipt);

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun the_admin_pause_stops_applying_blasts_share() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 1_500, 1_500, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    vault.schedule_protocol_bps(
        &fee_admin(),
        f.version(),
        bps::new(2_000),
        bps::new(2_000),
        f.clock(),
    );
    f.clock_mut().increment_for_testing(NOTICE_MS);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    vault.apply_protocol_bps(f.version(), f.clock());

    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
/// The pause is checked before the venue, so a paused buyback reports the pause.
fun a_paused_buyback_reports_the_pause_before_the_venue() {
    let mut scenario = vault_fixture::begin();
    let mut f = vault_fixture::start(&mut scenario);
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(&mut scenario, terms, 0, 0);
    let mut vault = vault_fixture::take_vault(&scenario);
    package_admin::pause(f.version_mut(), &pause_admin(), constants::admin_pause_bit!());

    let (taken_quote, receipt) = vault.take_buyback_quote(
        &vault_fixture::other_venue(),
        &buyback_admin(),
        f.version(),
        10,
    );

    destroy(taken_quote);
    destroy(receipt);

    abort
}

// === Test Helpers ===

/// Shares the test sale's vault and the test venue's standalone vault for the same sale, which
/// derive distinct IDs, and takes both, the first shared first.
fun share_two_vaults(
    f: &mut VaultFixture,
    scenario: &mut Scenario,
): (Vault<VAULT_FIXTURE, QUOTE>, Vault<VAULT_FIXTURE, QUOTE>) {
    let terms = f.terms_for(owner_split(), 0, 0, false, false);
    f.share_vault(scenario, terms, 0, 0);
    let first_id = test_scenario::most_recent_id_shared<Vault<VAULT_FIXTURE, QUOTE>>().destroy_some();
    let terms = vault_fixture::terms_sealed_by(vault_fixture::venue(), owner_split());
    f.share_vault(scenario, terms, 0, 0);
    let second_id = test_scenario::most_recent_id_shared<Vault<VAULT_FIXTURE, QUOTE>>().destroy_some();

    (scenario.take_shared_by_id(first_id), scenario.take_shared_by_id(second_id))
}

/// Owner 40%, auto-LP 20%, holder rewards 20%, burn 10%, and one address 10%.
fun every_route_split(): FeeSplit {
    fee_split::new(vector[
        fee_split::route(fee_split::owner_destination(), bps::new(4_000)),
        fee_split::route(fee_split::auto_lp_destination(), bps::new(2_000)),
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(2_000)),
        fee_split::route(fee_split::burn_destination(), bps::new(1_000)),
        fee_split::route(fee_split::address_destination(ROUTE_RECIPIENT), bps::new(1_000)),
    ])
}

fun fee_admin(): AdminWitness<FeeAdmin> { blast_acl::witness_for_testing() }

fun adapter_admin(): AdminWitness<AdapterAdmin> { blast_acl::witness_for_testing() }

fun cancel_admin(): AdminWitness<CancelAdmin> { blast_acl::witness_for_testing() }

fun buyback_admin(): AdminWitness<BuybackAdmin> { blast_acl::witness_for_testing() }

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_VAULT_PACKAGE>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, package_admin::{Self, PauseAdmin}};

use blast_core::{
    blast_core_events::ProtocolFeesPaid,
    blast_domain::{AdapterAdmin, BuybackAdmin, CancelAdmin, FeeAdmin},
    bps,
    fee_split::{Self, FeeSplit},
    migration,
    owner_proof
};

use blast_vault::{
    blast_vault_events::{
        Self,
        AutoLiquidityAdded,
        BuybackBurned,
        FeesCollected,
        OwnerBalancesClaimed,
        VaultCreated
    },
    blast_vault_package::{Self, BLAST_VAULT_PACKAGE},
    constants,
    vault::{Self, Vault},
    vault_fixture::{
        Self,
        QUOTE,
        SaleWitness,
        TestPosition,
        TestVenue,
        VAULT_FIXTURE,
        VaultFixture,
        owner_split
    }
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, coin::{Self, Coin}, event, test_scenario::{Self, Scenario}};
