// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::protocol_fees_tests;

// === Constants ===

const TREASURY: address = @0x7EA5;
const PARTNER: address = @0xBA27;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

// === Tests ===

#[test]
fun the_share_rounds_up_for_blast_and_leaves_the_rest_in_the_fee() {
    let mut ledger = new_ledger(option::none());
    let mut meme_fee = balance::create_for_testing<MEME>(1_001);
    let mut quote_fee = balance::create_for_testing<QUOTE>(3);

    let (meme, quote) = ledger.take_share(&mut meme_fee, &mut quote_fee, bps::new(3_000), bps::new(5_000));

    assert_eq!(meme, 301);
    assert_eq!(quote, 2);
    assert_eq!(meme_fee.value(), 700);
    assert_eq!(quote_fee.value(), 1);
    assert_balances(&ledger, 301, 2, 0);

    destroy(meme_fee);
    destroy(quote_fee);
    ledger.destroy_for_testing();
}

#[test]
fun a_ledger_without_a_partner_pays_everything_to_the_treasury() {
    let mut scenario = test_scenario::begin(@0x1);
    let treasury = blast_treasury::new_for_testing(TREASURY, scenario.ctx());
    let mut ledger = new_ledger(option::none());
    ledger.accrue(balance::create_for_testing(10), balance::create_for_testing(20));
    ledger.accrue_sui(balance::create_for_testing(30));

    ledger.pay(&treasury, scenario.ctx());

    assert_balances(&ledger, 0, 0, 0);
    let paid = event::events_by_type<ProtocolFeesPaid<MEME, QUOTE>>();
    assert_eq!(paid.length(), 1);
    let (origin, destination, meme, quote, sui, partner_id, partner_meme, partner_quote, partner_sui) =
        paid[0].paid_fields();
    assert_eq!(origin, ledger.origin());
    assert_eq!(destination, TREASURY);
    assert!(meme == 10 && quote == 20 && sui == 30);
    assert!(partner_id.is_none() && partner_meme == 0 && partner_quote == 0 && partner_sui == 0);

    scenario.next_tx(TREASURY);
    let sui_coin = scenario.take_from_address<Coin<SUI>>(TREASURY);
    assert_eq!(sui_coin.value(), 30);

    destroy(sui_coin);
    destroy(treasury);
    ledger.destroy_for_testing();
    scenario.end();
}

#[test]
fun a_bound_partner_takes_its_cut_of_every_asset_before_the_treasury() {
    let mut scenario = test_scenario::begin(@0x1);
    let treasury = blast_treasury::new_for_testing(TREASURY, scenario.ctx());
    let partner = blast_partners::new_for_testing(PARTNER, 3_000, scenario.ctx());
    let mut ledger = new_ledger(option::some(object::id(&partner)));
    ledger.accrue(balance::create_for_testing(1_001), balance::create_for_testing(10));
    ledger.accrue_sui(balance::create_for_testing(100));

    ledger.pay_with_partner(&treasury, &partner, scenario.ctx());

    let paid = event::events_by_type<ProtocolFeesPaid<MEME, QUOTE>>();
    assert_eq!(paid.length(), 1);
    let (origin, destination, meme, quote, sui, partner_id, partner_meme, partner_quote, partner_sui) =
        paid[0].paid_fields();
    assert_eq!(origin, ledger.origin());
    assert_eq!(destination, TREASURY);
    assert_eq!(partner_id, option::some(object::id(&partner)));
    assert_eq!(ledger.partner_id(), partner_id);
    // The partner's cut rounds down, so Blast keeps the remainder of each asset.
    assert!(partner_meme == 300 && partner_quote == 3 && partner_sui == 30);
    assert!(meme == 701 && quote == 7 && sui == 70);
    assert_balances(&ledger, 0, 0, 0);

    destroy(partner);
    destroy(treasury);
    ledger.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
fun a_ledger_bound_to_a_partner_cannot_skip_its_cut() {
    let mut scenario = test_scenario::begin(@0x1);
    let treasury = blast_treasury::new_for_testing(TREASURY, scenario.ctx());
    let partner = blast_partners::new_for_testing(PARTNER, 3_000, scenario.ctx());
    let mut ledger = new_ledger(option::some(object::id(&partner)));

    ledger.pay(&treasury, scenario.ctx());

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
fun a_ledger_pays_only_with_its_own_partner() {
    let mut scenario = test_scenario::begin(@0x1);
    let treasury = blast_treasury::new_for_testing(TREASURY, scenario.ctx());
    let named = blast_partners::new_for_testing(PARTNER, 3_000, scenario.ctx());
    let other = blast_partners::new_for_testing(PARTNER, 3_000, scenario.ctx());
    let mut ledger = new_ledger(option::some(object::id(&named)));

    ledger.pay_with_partner(&treasury, &other, scenario.ctx());

    abort
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidPair, location = blast_core::protocol_fees)]
fun a_ledger_rejects_one_type_for_both_assets() {
    protocol_fees::new<MEME, MEME>(object::id_from_address(@0x0), option::none()).destroy_for_testing();
}

// === Test Helpers ===

fun assert_balances(ledger: &Ledger<MEME, QUOTE>, meme: u64, quote: u64, sui: u64) {
    let (held_meme, held_quote, held_sui) = ledger.balances();
    assert!(held_meme == meme && held_quote == quote && held_sui == sui);
}

fun new_ledger(partner_id: Option<ID>): Ledger<MEME, QUOTE> {
    protocol_fees::new(object::id_from_address(@0x5A1E), partner_id)
}

// === Imports ===

use blast_core::{blast_treasury, bps, protocol_fees::{Self, Ledger, ProtocolFeesPaid}};

use blast_partners::blast_partners;

use std::unit_test::{assert_eq, destroy};

use sui::{balance, coin::Coin, event, sui::SUI, test_scenario};
