// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_otc::blast_fun_otc_tests;

// === Constants ===

const MAKER: address = @0xAA;

const TAKER: address = @0xBB;

const OTHER: address = @0xCC;

const OFFERED_AMOUNT: u64 = 1_000;

/// Not a divisor of `OFFERED_AMOUNT`, so partial fills exercise the rounding.
const WANTED_AMOUNT: u64 = 333;

// === Test-Only Types ===

public struct OFFERED() has drop;

public struct WANTED() has drop;

/// Single-transaction fixture holding any number of unshared offers.
public struct UnitFixture {
    scenario: Scenario,
    offers: vector<Offer<OFFERED, WANTED>>,
}

/// Shared offer lifecycle with maker payout inspection.
public struct OfferFixture {
    scenario: Scenario,
    offer: Option<Offer<OFFERED, WANTED>>,
    created: OfferCreated,
    offer_id: ID,
}

// === Tests ===

#[test]
fun full_take_pays_the_maker_exactly_the_wanted_amount_and_replays_events() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.assert_created(option::none(), false);

        let (bought, change) = f.take(OFFERED_AMOUNT, 400);
        assert_eq!(bought, OFFERED_AMOUNT);
        assert_eq!(change, 67);

        let taken = collect_one<OfferTaken>();
        let (offer_id, amount, paid) = taken.offer_taken_fields();
        assert_eq!(offer_id, f.offer_id());
        assert_eq!(amount, OFFERED_AMOUNT);
        assert_eq!(paid, WANTED_AMOUNT);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), WANTED_AMOUNT);
        assert_eq!(f.cancel(), 0);

        let canceled = collect_one<OfferCanceled>();
        let (offer_id, refund) = canceled.offer_canceled_fields();
        assert_eq!(offer_id, f.offer_id());
        assert_eq!(refund, 0);
    });

    fixture.end();
}

#[test]
fun partial_fills_round_every_cost_up_for_the_maker() {
    let mut fixture = start_offer(option::none(), true);

    fixture.next_tx!(TAKER, |f| {
        f.assert_created(option::none(), true);

        // 3 * 333 / 1_000 = 0.999 rounds up to one unit.
        let (bought, change) = f.take(3, 1);
        assert_eq!(bought, 3);
        assert_eq!(change, 0);

        let taken = collect_one<OfferTaken>();
        let (_, amount, paid) = taken.offer_taken_fields();
        assert_eq!(amount, 3);
        assert_eq!(paid, 1);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 1);
    });

    fixture.next_tx!(OTHER, |f| {
        // 500 * 333 / 1_000 = 166.5 rounds up to 167.
        let (bought, change) = f.take(500, 200);
        assert_eq!(bought, 500);
        assert_eq!(change, 33);

        let taken = collect_one<OfferTaken>();
        let (_, amount, paid) = taken.offer_taken_fields();
        assert_eq!(amount, 500);
        assert_eq!(paid, 167);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 167);
    });

    fixture.next_tx!(TAKER, |f| {
        // 497 * 333 / 1_000 = 165.501 rounds up to 166; the maker receives 334 in total.
        let (bought, change) = f.take(497, 166);
        assert_eq!(bought, 497);
        assert_eq!(change, 0);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 166);
        assert_eq!(f.cancel(), 0);
    });

    fixture.end();
}

#[test]
fun maker_cancel_returns_the_unfilled_remainder() {
    let mut fixture = start_offer(option::none(), true);

    fixture.next_tx!(TAKER, |f| {
        let (bought, change) = f.take(400, 134);
        assert_eq!(bought, 400);
        assert_eq!(change, 0);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 134);
        assert_eq!(f.cancel(), 600);

        let canceled = collect_one<OfferCanceled>();
        let (offer_id, refund) = canceled.offer_canceled_fields();
        assert_eq!(offer_id, f.offer_id());
        assert_eq!(refund, 600);
    });

    fixture.end();
}

#[test]
fun maker_cancel_of_an_untouched_offer_returns_the_full_escrow() {
    let mut fixture = start_offer(option::some(TAKER), false);

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.cancel(), OFFERED_AMOUNT);

        let canceled = collect_one<OfferCanceled>();
        let (_, refund) = canceled.offer_canceled_fields();
        assert_eq!(refund, OFFERED_AMOUNT);
    });

    fixture.end();
}

#[test]
fun named_taker_offer_accepts_its_taker() {
    let mut fixture = start_offer(option::some(TAKER), false);

    fixture.next_tx!(TAKER, |f| {
        f.assert_created(option::some(TAKER), false);

        let (bought, change) = f.take(OFFERED_AMOUNT, WANTED_AMOUNT);
        assert_eq!(bought, OFFERED_AMOUNT);
        assert_eq!(change, 0);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), WANTED_AMOUNT);
    });

    fixture.end();
}

#[test]
fun named_taker_may_fill_a_partial_offer_in_steps() {
    let mut fixture = start_offer(option::some(TAKER), true);

    fixture.next_tx!(TAKER, |f| {
        f.assert_created(option::some(TAKER), true);

        let (bought, _) = f.take(400, 134);
        assert_eq!(bought, 400);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 134);
    });

    fixture.next_tx!(TAKER, |f| {
        // 600 * 333 / 1_000 = 199.8 rounds up to 200.
        let (bought, change) = f.take(600, 200);
        assert_eq!(bought, 600);
        assert_eq!(change, 0);
    });

    fixture.next_tx!(MAKER, |f| {
        assert_eq!(f.take_maker_payout(), 200);
        assert_eq!(f.cancel(), 0);
    });

    fixture.end();
}

#[test]
fun taken_events_replay_to_the_refund_and_the_maker_receipts() {
    let mut fixture = start_offer(option::none(), true);
    let mut sold = 0;
    let mut paid = 0;
    let mut received = 0;

    fixture.next_tx!(TAKER, |f| {
        f.take(3, 1);

        let taken = collect_one<OfferTaken>();
        let (_, amount, cost) = taken.offer_taken_fields();
        sold = sold + amount;
        paid = paid + cost;
    });

    fixture.next_tx!(MAKER, |f| {
        received = received + f.take_maker_payout();
    });

    fixture.next_tx!(OTHER, |f| {
        f.take(500, 200);

        let taken = collect_one<OfferTaken>();
        let (_, amount, cost) = taken.offer_taken_fields();
        sold = sold + amount;
        paid = paid + cost;
    });

    fixture.next_tx!(MAKER, |f| {
        received = received + f.take_maker_payout();
    });

    fixture.next_tx!(TAKER, |f| {
        f.take(250, 100);

        let taken = collect_one<OfferTaken>();
        let (_, amount, cost) = taken.offer_taken_fields();
        sold = sold + amount;
        paid = paid + cost;
    });

    fixture.next_tx!(MAKER, |f| {
        received = received + f.take_maker_payout();
        let refund = f.cancel();

        let canceled = collect_one<OfferCanceled>();
        let (_, emitted_refund) = canceled.offer_canceled_fields();
        let (_, _, _, _, _, offered_amount, _) = f.created.offer_created_fields();
        assert_eq!(emitted_refund, refund);
        assert_eq!(refund, offered_amount - sold);
    });

    assert_eq!(sold, 753);
    assert_eq!(paid, 1 + 167 + 84);
    assert_eq!(received, paid);

    fixture.end();
}

#[test]
fun costs_round_up_only_on_a_remainder() {
    let mut fixture = start_unit();

    // Rate 1/4: exact fills pay the exact cost; a remainder adds one unit.
    fixture.create(1_000, 250, option::none(), true);
    let (_, change) = fixture.take(0, 4, 100);
    assert_eq!(change, 99);
    let (_, change) = fixture.take(0, 5, 100);
    assert_eq!(change, 98);
    assert_eq!(fixture.cancel(0), 991);

    // Rate 1/1_000: no fill is free, so the maker can receive one unit more per fill.
    fixture.create(1_000, 1, option::none(), true);
    let (_, change) = fixture.take(0, 1, 100);
    assert_eq!(change, 99);
    let (_, change) = fixture.take(0, 999, 100);
    assert_eq!(change, 99);
    assert_eq!(fixture.cancel(0), 0);

    // Rate 10/3: 1 unit costs 3.33 → 4, 2 units cost 6.67 → 7.
    fixture.create(3, 10, option::none(), true);
    let (_, change) = fixture.take(0, 1, 100);
    assert_eq!(change, 96);
    let (_, change) = fixture.take(0, 2, 100);
    assert_eq!(change, 93);
    assert_eq!(fixture.cancel(0), 0);

    fixture.end();
}

#[test]
fun offer_composes_within_one_transaction_before_sharing() {
    let mut fixture = start_unit();
    fixture.create(OFFERED_AMOUNT, WANTED_AMOUNT, option::none(), true);
    let offer_id = fixture.offer_id(0);

    let (bought, change) = fixture.take(0, 250, 100);
    assert_eq!(bought, 250);
    assert_eq!(change, 16);
    assert_eq!(fixture.cancel(0), 750);

    let created = collect_one<OfferCreated>();
    let (created_id, _, _, taker, partial_fills, offered_amount, wanted_amount) =
        created.offer_created_fields();
    let taken = collect_one<OfferTaken>();
    let (taken_id, amount, paid) = taken.offer_taken_fields();
    let canceled = collect_one<OfferCanceled>();
    let (canceled_id, refund) = canceled.offer_canceled_fields();

    assert_eq!(created_id, offer_id);
    assert!(taker.is_none());
    assert!(partial_fills);
    assert_eq!(offered_amount, OFFERED_AMOUNT);
    assert_eq!(wanted_amount, WANTED_AMOUNT);
    assert_eq!(taken_id, offer_id);
    assert_eq!(amount, 250);
    assert_eq!(paid, 84);
    assert_eq!(canceled_id, offer_id);
    assert_eq!(refund, 750);

    fixture.end();
}

#[test]
fun offers_in_one_transaction_emit_events_matched_by_id() {
    let mut fixture = start_unit();
    fixture.create(OFFERED_AMOUNT, WANTED_AMOUNT, option::none(), true);
    fixture.create(500, 100, option::some(MAKER), false);
    let first_id = fixture.offer_id(0);
    let second_id = fixture.offer_id(1);

    fixture.take(1, 500, 100);
    fixture.take(0, 250, 100);
    assert_eq!(fixture.cancel(1), 0);
    assert_eq!(fixture.cancel(0), 750);

    let created = event::events_by_type<OfferCreated>();
    let (id, _, _, taker, partial_fills, offered_amount, wanted_amount) =
        created[0].offer_created_fields();
    assert_eq!(id, first_id);
    assert!(taker.is_none());
    assert!(partial_fills);
    assert_eq!(offered_amount, OFFERED_AMOUNT);
    assert_eq!(wanted_amount, WANTED_AMOUNT);
    let (id, _, _, taker, partial_fills, offered_amount, wanted_amount) =
        created[1].offer_created_fields();
    assert_eq!(id, second_id);
    assert_eq!(taker, option::some(MAKER));
    assert!(!partial_fills);
    assert_eq!(offered_amount, 500);
    assert_eq!(wanted_amount, 100);

    let taken = event::events_by_type<OfferTaken>();
    let (id, amount, paid) = taken[0].offer_taken_fields();
    assert_eq!(id, second_id);
    assert_eq!(amount, 500);
    assert_eq!(paid, 100);
    let (id, amount, paid) = taken[1].offer_taken_fields();
    assert_eq!(id, first_id);
    assert_eq!(amount, 250);
    assert_eq!(paid, 84);

    let canceled = event::events_by_type<OfferCanceled>();
    let (id, refund) = canceled[0].offer_canceled_fields();
    assert_eq!(id, second_id);
    assert_eq!(refund, 0);
    let (id, refund) = canceled[1].offer_canceled_fields();
    assert_eq!(id, first_id);
    assert_eq!(refund, 750);

    fixture.end();
}

#[test]
fun maximum_width_fills_multiply_without_overflow() {
    let max = std::u64::max_value!();
    let mut fixture = start_unit();
    fixture.create(max, max, option::none(), true);

    let (bought, change) = fixture.take(0, max - 1, max);
    assert_eq!(bought, max - 1);
    assert_eq!(change, 1);

    let (bought, change) = fixture.take(0, 1, 1);
    assert_eq!(bought, 1);
    assert_eq!(change, 0);
    assert_eq!(fixture.cancel(0), 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EInvalidTaker,
    location = blast_fun_otc::blast_fun_otc,
)]
fun constructor_rejects_zero_taker_before_zero_amounts() {
    let mut fixture = start_unit();
    fixture.create(0, 0, option::some(@0x0), false);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EZeroOffered,
    location = blast_fun_otc::blast_fun_otc,
)]
fun constructor_rejects_zero_offered_before_zero_wanted() {
    let mut fixture = start_unit();
    fixture.create(0, 0, option::none(), false);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EZeroWanted,
    location = blast_fun_otc::blast_fun_otc,
)]
fun constructor_rejects_zero_wanted() {
    let mut fixture = start_unit();
    fixture.create(1, 0, option::none(), false);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EZeroWanted,
    location = blast_fun_otc::blast_fun_otc,
)]
fun constructor_rejects_zero_wanted_before_the_same_coin_type() {
    let mut fixture = start_unit();
    fixture.create_with_same_coin(1, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::ESameCoin,
    location = blast_fun_otc::blast_fun_otc,
)]
fun constructor_rejects_the_same_coin_type() {
    let mut fixture = start_unit();
    fixture.create_with_same_coin(OFFERED_AMOUNT, WANTED_AMOUNT);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::ENotTaker,
    location = blast_fun_otc::blast_fun_otc,
)]
fun named_taker_offer_rejects_another_sender_before_amount_checks() {
    let mut fixture = start_offer(option::some(TAKER), false);

    fixture.next_tx!(OTHER, |f| {
        f.take(0, WANTED_AMOUNT);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EZeroAmount,
    location = blast_fun_otc::blast_fun_otc,
)]
fun take_rejects_zero_amount_before_the_full_take_rule() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.take(0, WANTED_AMOUNT);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EAmountExceedsBalance,
    location = blast_fun_otc::blast_fun_otc,
)]
fun take_rejects_amount_above_the_balance_before_the_full_take_rule() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.take(OFFERED_AMOUNT + 1, WANTED_AMOUNT + 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EAmountExceedsBalance,
    location = blast_fun_otc::blast_fun_otc,
)]
fun taken_offer_rejects_another_take() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.take(OFFERED_AMOUNT, WANTED_AMOUNT);
    });

    fixture.next_tx!(OTHER, |f| {
        f.take(1, WANTED_AMOUNT);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::EPartialFillsDisabled,
    location = blast_fun_otc::blast_fun_otc,
)]
fun all_or_nothing_offer_rejects_a_partial_take() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.take(OFFERED_AMOUNT - 1, WANTED_AMOUNT);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::balance::ENotEnough, location = sui::balance)]
fun take_rejects_a_payment_below_the_cost() {
    let mut fixture = start_offer(option::none(), false);

    fixture.next_tx!(TAKER, |f| {
        f.take(OFFERED_AMOUNT, WANTED_AMOUNT - 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_otc::blast_fun_otc::ENotMaker,
    location = blast_fun_otc::blast_fun_otc,
)]
fun cancel_rejects_a_sender_other_than_the_maker() {
    let mut fixture = start_offer(option::none(), true);

    fixture.next_tx!(TAKER, |f| {
        f.cancel();
    });

    fixture.end();
}

// === Test Helpers ===

macro fun offer_next_tx(
    $fixture: &mut OfferFixture,
    $sender: address,
    $fn: |&mut OfferFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_unit(): UnitFixture {
    UnitFixture {
        scenario: test_scenario::begin(MAKER),
        offers: vector[],
    }
}

fun unit_create(
    self: &mut UnitFixture,
    offered_amount: u64,
    wanted_amount: u64,
    taker: Option<address>,
    partial_fills: bool,
) {
    let offered = coin::mint_for_testing<OFFERED>(offered_amount, self.scenario.ctx());
    let offer = otc::new<OFFERED, WANTED>(
        offered,
        wanted_amount,
        taker,
        partial_fills,
        self.scenario.ctx(),
    );
    self.offers.push_back(offer);
}

fun unit_create_with_same_coin(
    self: &mut UnitFixture,
    offered_amount: u64,
    wanted_amount: u64,
) {
    let offered = coin::mint_for_testing<OFFERED>(offered_amount, self.scenario.ctx());
    let offer = otc::new<OFFERED, OFFERED>(
        offered,
        wanted_amount,
        option::none(),
        false,
        self.scenario.ctx(),
    );

    destroy(offer);
}

fun unit_offer_id(self: &UnitFixture, index: u64): ID {
    object::id(&self.offers[index])
}

fun unit_take(
    self: &mut UnitFixture,
    index: u64,
    amount: u64,
    budget: u64,
): (u64, u64) {
    let mut payment = coin::mint_for_testing<WANTED>(budget, self.scenario.ctx());
    let bought = self.offers[index].take(amount, &mut payment, self.scenario.ctx());

    (bought.burn_for_testing(), payment.burn_for_testing())
}

fun unit_cancel(self: &mut UnitFixture, index: u64): u64 {
    self.offers.remove(index).cancel(self.scenario.ctx()).burn_for_testing()
}

fun unit_end(self: UnitFixture) {
    destroy(self);
}

fun start_offer(taker: Option<address>, partial_fills: bool): OfferFixture {
    let mut scenario = test_scenario::begin(MAKER);
    let offered = coin::mint_for_testing<OFFERED>(OFFERED_AMOUNT, scenario.ctx());
    let offer = otc::new<OFFERED, WANTED>(
        offered,
        WANTED_AMOUNT,
        taker,
        partial_fills,
        scenario.ctx(),
    );
    let offer_id = object::id(&offer);
    let created = collect_one<OfferCreated>();

    offer.share();
    scenario.next_tx(MAKER);
    let offer = scenario.take_shared<Offer<OFFERED, WANTED>>();

    OfferFixture {
        scenario,
        offer: option::some(offer),
        created,
        offer_id,
    }
}

fun collect_one<T: copy + drop>(): T {
    let mut events = event::events_by_type<T>();
    assert!(events.length() == 1);
    events.pop_back()
}

fun offer_assert_created(
    self: &OfferFixture,
    expected_taker: Option<address>,
    expected_partial_fills: bool,
) {
    let (
        offer_id,
        offered_type,
        wanted_type,
        taker,
        partial_fills,
        offered_amount,
        wanted_amount,
    ) = self.created.offer_created_fields();

    assert_eq!(offer_id, self.offer_id);
    assert_eq!(offered_type, std::type_name::with_original_ids<OFFERED>());
    assert_eq!(wanted_type, std::type_name::with_original_ids<WANTED>());
    assert_eq!(taker, expected_taker);
    assert_eq!(partial_fills, expected_partial_fills);
    assert_eq!(offered_amount, OFFERED_AMOUNT);
    assert_eq!(wanted_amount, WANTED_AMOUNT);
}

fun offer_take(self: &mut OfferFixture, amount: u64, budget: u64): (u64, u64) {
    let mut payment = coin::mint_for_testing<WANTED>(budget, self.scenario.ctx());
    let bought = self.offer.borrow_mut().take(amount, &mut payment, self.scenario.ctx());

    (bought.burn_for_testing(), payment.burn_for_testing())
}

fun offer_cancel(self: &mut OfferFixture): u64 {
    self.offer.extract().cancel(self.scenario.ctx()).burn_for_testing()
}

fun offer_offer_id(self: &OfferFixture): ID {
    self.offer_id
}

fun offer_take_maker_payout(self: &OfferFixture): u64 {
    self.scenario.take_from_sender<Coin<WANTED>>().burn_for_testing()
}

fun offer_end(self: OfferFixture) {
    destroy(self);
}

// === Imports ===

use blast_fun_otc::blast_fun_otc::{
    Self as otc,
    Offer,
    OfferCanceled,
    OfferCreated,
    OfferTaken,
};

use std::unit_test::{assert_eq, destroy};

use sui::{coin::{Self, Coin}, event, test_scenario::{Self, Scenario}};

use fun offer_assert_created as OfferFixture.assert_created;

use fun offer_cancel as OfferFixture.cancel;

use fun offer_end as OfferFixture.end;

use fun offer_next_tx as OfferFixture.next_tx;

use fun offer_offer_id as OfferFixture.offer_id;

use fun offer_take as OfferFixture.take;

use fun offer_take_maker_payout as OfferFixture.take_maker_payout;

use fun unit_cancel as UnitFixture.cancel;

use fun unit_create as UnitFixture.create;

use fun unit_create_with_same_coin as UnitFixture.create_with_same_coin;

use fun unit_end as UnitFixture.end;

use fun unit_offer_id as UnitFixture.offer_id;

use fun unit_take as UnitFixture.take;
