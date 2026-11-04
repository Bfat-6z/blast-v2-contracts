// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_partners::partner_list_tests;

// === Constants ===

const RECIPIENT: address = @0xFEE;
const ADDED_AT_MS: u64 = 1_000;

// === Tests ===

#[test]
fun an_added_partner_is_accepted_at_once_and_named_by_its_owner() {
    let (owner, mut list, partner, clock) = start();
    list.add(&partner);

    list.assert_accepted(object::id(&partner), &clock);
    let added = event::events_by_type<PartnerAdded>();
    assert_eq!(added.length(), 1);
    let (list_owner, partner_id) = added[0].partner_added_fields();
    assert_eq!(list_owner, owner.to_inner());
    assert_eq!(partner_id, object::id(&partner));
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
fun a_partner_never_added_is_not_accepted() {
    let (owner, list, partner, clock) = start();

    list.assert_accepted(object::id(&partner), &clock);
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::partner_list)]
fun adding_an_accepted_partner_aborts() {
    let (owner, mut list, partner, clock) = start();
    list.add(&partner);

    list.add(&partner);
    end(owner, list, partner, clock);
}

#[test]
/// A removed partner stays accepted through the last millisecond of the fixed notice.
fun a_removed_partner_stays_accepted_for_the_fixed_notice() {
    let (owner, mut list, partner, mut clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);

    list.remove(partner_id, &clock);

    let acceptance_ends_at_ms = ADDED_AT_MS + partners::delay_ms();
    let removed = event::events_by_type<PartnerRemoved>();
    assert_eq!(removed.length(), 1);
    let (list_owner, removed_partner_id, removal_ends_at_ms) = removed[0].partner_removed_fields();
    assert_eq!(list_owner, owner.to_inner());
    assert_eq!(removed_partner_id, partner_id);
    assert_eq!(removal_ends_at_ms, acceptance_ends_at_ms);
    clock.set_for_testing(acceptance_ends_at_ms - 1);
    list.assert_accepted(partner_id, &clock);
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
fun a_removed_partner_is_refused_once_the_notice_ends() {
    let (owner, mut list, partner, mut clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);
    list.remove(partner_id, &clock);

    clock.set_for_testing(ADDED_AT_MS + partners::delay_ms());
    list.assert_accepted(partner_id, &clock);
    end(owner, list, partner, clock);
}

#[test]
fun adding_a_partner_cancels_its_pending_removal() {
    let (owner, mut list, partner, mut clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);
    list.remove(partner_id, &clock);

    list.add(&partner);

    clock.set_for_testing(ADDED_AT_MS + partners::delay_ms());
    list.assert_accepted(partner_id, &clock);
    assert_eq!(event::events_by_type<PartnerAdded>().length(), 2);
    end(owner, list, partner, clock);
}

#[test]
fun adding_a_partner_whose_notice_ended_accepts_it_again() {
    let (owner, mut list, partner, mut clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);
    list.remove(partner_id, &clock);
    clock.set_for_testing(ADDED_AT_MS + partners::delay_ms());

    list.add(&partner);

    list.assert_accepted(partner_id, &clock);
    // A second removal starts its own notice from now.
    list.remove(partner_id, &clock);
    let removed = event::events_by_type<PartnerRemoved>();
    let (_, _, acceptance_ends_at_ms) = removed[1].partner_removed_fields();
    assert_eq!(acceptance_ends_at_ms, ADDED_AT_MS + 2 * partners::delay_ms());
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::partner_list)]
fun removing_a_partner_whose_removal_is_pending_aborts() {
    let (owner, mut list, partner, clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);
    list.remove(partner_id, &clock);

    list.remove(partner_id, &clock);
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
fun removing_a_partner_never_added_aborts() {
    let (owner, mut list, partner, clock) = start();
    let partner_id = object::id(&partner);

    list.remove(partner_id, &clock);
    end(owner, list, partner, clock);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
/// Precedence: once the notice ends, removing again reports the refusal, not an unchanged value.
fun removing_a_partner_whose_notice_ended_reports_it_not_accepted() {
    let (owner, mut list, partner, mut clock) = start();
    list.add(&partner);
    let partner_id = object::id(&partner);
    list.remove(partner_id, &clock);
    clock.set_for_testing(ADDED_AT_MS + partners::delay_ms());

    list.remove(partner_id, &clock);
    end(owner, list, partner, clock);
}

#[test]
/// Each list answers only for its own partners.
fun lists_are_independent() {
    let (owner, mut list, partner, clock) = start();
    let mut ctx = tx_context::new_from_hint(@0xB0B, 1, 0, 0, 0);
    let other_owner = object::new(&mut ctx);
    let mut other_list = partner_list::new(&other_owner, &mut ctx);
    let other_partner = partners::new_for_testing(RECIPIENT, 0, &mut ctx);
    list.add(&partner);
    other_list.add(&other_partner);

    other_list.remove(object::id(&other_partner), &clock);

    list.assert_accepted(object::id(&partner), &clock);
    let removed = event::events_by_type<PartnerRemoved>();
    let (list_owner, _, _) = removed[0].partner_removed_fields();
    assert_eq!(list_owner, other_owner.to_inner());
    other_list.destroy_for_testing();
    other_owner.delete();
    destroy(other_partner);
    end(owner, list, partner, clock);
}

// === Test Helpers ===

fun start(): (UID, PartnerList, Partner, Clock) {
    let mut ctx = tx_context::dummy();
    let owner = object::new(&mut ctx);
    let list = partner_list::new(&owner, &mut ctx);
    let partner = partners::new_for_testing(RECIPIENT, 1_000, &mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(ADDED_AT_MS);

    (owner, list, partner, clock)
}

fun end(owner: UID, list: PartnerList, partner: Partner, clock: Clock) {
    list.destroy_for_testing();
    owner.delete();
    destroy(partner);
    clock.destroy_for_testing();
}

// === Imports ===

use blast_partners::{
    blast_partners::{Self as partners, Partner},
    partner_list::{Self, PartnerAdded, PartnerList, PartnerRemoved}
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, event};
