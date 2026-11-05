// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::creation_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;

/// Where the test partner is paid, and its cut of Blast's fee: 40%.
const PARTNER: address = @0x9A27;
const PARTNER_CUT_BPS: u64 = 4_000;

/// When the administrator removes a partner in the removal tests.
const REMOVED_AT_MS: u64 = 1_000;

// === Test-Only Types ===

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct VENUE() has drop;

// === Tests ===

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Publication shares one policy that allows no Quote type and no venue.
fun publication_shares_a_policy_that_allows_nothing() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    creation_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<CreationPolicy>();

    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    abort
}

#[test]
/// The administrator allows a Quote type and a venue, and each change emits its type.
fun the_admin_allows_a_quote_and_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_quote_allowed<QUOTE>(&package_version, &listing_admin(), true);
    policy.set_venue_allowed_for_testing<VENUE>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );

    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    assert_eq!(last_event<QuoteAllowed<QUOTE>>().quote_allowed_fields(), true);
    let (owner, _, admission, _) = last_event<
        SetApplied<VenueKey, TypeName>,
    >().set_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(admission.member(), option::some(type_name<VENUE>()));

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Allowing one Quote type allows no other.
fun allowing_one_quote_allows_no_other() {
    let policy = allowing<QUOTE, VENUE>();

    policy.assert_allowed<OTHER_QUOTE>(type_name::with_original_ids<VENUE>());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EVenueNotAllowed,
    location = blast_presale::creation_policy,
)]
/// An allowed Quote type is not enough without an allowed venue.
fun an_allowed_quote_still_needs_an_allowed_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();
    policy.set_quote_allowed<QUOTE>(&package_version, &listing_admin(), true);

    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Disallowing a Quote type emits it and stops later creations from raising it.
fun disallowing_a_quote_stops_later_creations() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing<QUOTE, VENUE>();

    policy.set_quote_allowed<QUOTE>(&package_version, &listing_admin(), false);

    assert_eq!(last_event<QuoteAllowed<QUOTE>>().quote_allowed_fields(), false);
    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EVenueNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Disallowing a venue emits it and stops later creations through it.
fun disallowing_a_venue_stops_later_creations() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing<QUOTE, VENUE>();

    policy.set_venue_allowed_for_testing<VENUE>(
        &package_version,
        &venue_admin(),
        false,
        &mut sui::tx_context::dummy()
    );

    let (owner, _, member) = last_event<
        MemberRemoved<VenueKey, TypeName>,
    >().member_removed_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(member, type_name<VENUE>());
    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_allowed_quote_cannot_be_allowed_again() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing<QUOTE, VENUE>();

    policy.set_quote_allowed<QUOTE>(&package_version, &listing_admin(), true);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_quote_cannot_be_disallowed() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing<QUOTE, VENUE>();

    policy.set_quote_allowed<OTHER_QUOTE>(&package_version, &listing_admin(), false);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUnchanged,
    location = blast_admin::delayed_set,
)]
fun an_allowed_venue_cannot_be_allowed_again() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing<QUOTE, VENUE>();

    policy.set_venue_allowed_for_testing<VENUE>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUnchanged,
    location = blast_admin::delayed_set,
)]
fun an_unlisted_venue_cannot_be_disallowed() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<VENUE>(
        &package_version,
        &venue_admin(),
        false,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidVenue,
    location = blast_presale::creation_policy,
)]
/// Any caller can make a primitive, so allowing one would let anyone create and migrate sales.
fun a_primitive_cannot_be_allowed_as_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<u64>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidVenue,
    location = blast_presale::creation_policy,
)]
/// Any caller can make a vector of droppable values, so it is rejected like a primitive.
fun a_vector_cannot_be_allowed_as_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<vector<VENUE>>(
        &package_version,
        &venue_admin(),
        true,
     &mut sui::tx_context::dummy());
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidVenue,
    location = blast_presale::creation_policy,
)]
/// Any caller can make `TypeName` with `type_name::with_original_ids`, so a stdlib type is rejected.
fun a_stdlib_type_cannot_be_allowed_as_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<TypeName>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidVenue,
    location = blast_presale::creation_policy,
)]
/// Any caller can make an `Option<VENUE>` with `option::none`, so a generic stdlib type wrapping
/// a reviewed witness is rejected too.
fun an_option_of_a_witness_cannot_be_allowed_as_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<Option<VENUE>>(
        &package_version,
        &venue_admin(),
        true,
     &mut sui::tx_context::dummy());
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidVenue,
    location = blast_presale::creation_policy,
)]
/// Any caller can make an `ID` with `object::id_from_address`, so a Sui framework type is rejected.
fun a_sui_framework_type_cannot_be_allowed_as_a_venue() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<ID>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUnchanged,
    location = blast_admin::delayed_set,
)]
/// Disallowing never needs the struct check: a primitive can never have been allowed.
fun disallowing_a_primitive_is_an_unchanged_allowance() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    policy.set_venue_allowed_for_testing<u64>(
        &package_version,
        &venue_admin(),
        false,
        &mut sui::tx_context::dummy()
    );
    std::unit_test::destroy(package_version);
    abort
}

// --- Partners ---

#[test]
/// The administrator lets new presales name a partner at once, and the change emits it.
fun an_added_partner_is_accepted_at_once() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);

    policy.add_partner(&package_version, &fee_admin(), &partner);

    policy.assert_partner_at(object::id(&partner), 0);
    let (owner, added_id) = last_event<PartnerAdded>().partner_added_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(added_id, object::id(&partner));
    destroy(partner);
    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
/// A partner the administrator never added cannot be named.
fun an_unlisted_partner_is_not_accepted() {
    let mut ctx = tx_context::dummy();
    let policy = creation_policy::new_for_testing(&mut ctx);
    let partner = new_partner(&mut ctx);

    policy.assert_partner_at(object::id(&partner), 0);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
/// A removed partner stays accepted until one millisecond before Blast's partner delay ends, and
/// is refused from then on.
fun a_removed_partner_is_accepted_until_its_delay_ends() {
    let mut ctx = tx_context::dummy();
    let (policy, partner_id) = policy_with_removed_partner(&mut ctx);
    let acceptance_ends_at_ms = REMOVED_AT_MS + partners::delay_ms();

    let (owner, removed_id, removed_acceptance_ends_at_ms) = last_event<PartnerRemoved>()
        .partner_removed_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(removed_id, partner_id);
    assert_eq!(removed_acceptance_ends_at_ms, acceptance_ends_at_ms);
    policy.assert_partner_at(partner_id, acceptance_ends_at_ms - 1);

    policy.assert_partner_at(partner_id, acceptance_ends_at_ms);
    abort
}

#[test]
/// Adding a partner whose removal is pending cancels the removal.
fun re_adding_a_partner_cancels_its_removal() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&package_version, &fee_admin(), &partner);
    policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);

    policy.add_partner(&package_version, &fee_admin(), &partner);

    policy.assert_partner_at(object::id(&partner), std::u64::max_value!() - 1);
    destroy(partner);
    clock.destroy_for_testing();
    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
/// Adding a partner whose delay has ended accepts it again.
fun re_adding_a_removed_partner_accepts_it_again() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);
    let mut clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&package_version, &fee_admin(), &partner);
    policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);
    clock.set_for_testing(REMOVED_AT_MS + partners::delay_ms());

    policy.add_partner(&package_version, &fee_admin(), &partner);

    policy.assert_partner_at(object::id(&partner), clock.timestamp_ms());
    destroy(partner);
    clock.destroy_for_testing();
    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EUnchanged,
    location = blast_partners::partner_list,
)]
fun an_accepted_partner_cannot_be_added_again() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);
    policy.add_partner(&package_version, &fee_admin(), &partner);

    policy.add_partner(&package_version, &fee_admin(), &partner);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EUnchanged,
    location = blast_partners::partner_list,
)]
/// A pending removal cannot be restarted to push its delay back.
fun a_removed_partner_cannot_be_removed_again() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&package_version, &fee_admin(), &partner);
    policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);

    policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_partners::errors::EPartnerNotAccepted,
    location = blast_partners::partner_list,
)]
fun an_unlisted_partner_cannot_be_removed() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);

    policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_version_cannot_allow_quotes() {
    let mut package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = allowing_nothing();

    package_version.set_version_for_testing(2);
    policy.set_quote_allowed<QUOTE>(&package_version, &listing_admin(), true);
    policy.set_venue_allowed_for_testing<VENUE>(
        &package_version,
        &venue_admin(),
        true,
        &mut sui::tx_context::dummy()
    );

    policy.assert_allowed<QUOTE>(type_name::with_original_ids<VENUE>());
    assert_eq!(last_event<QuoteAllowed<QUOTE>>().quote_allowed_fields(), true);
    let (owner, _, admission, _) = last_event<
        SetApplied<VenueKey, TypeName>,
    >().set_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(admission.member(), option::some(type_name<VENUE>()));

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_version_cannot_accept_partners() {
    let mut ctx = tx_context::dummy();
    let mut package_version = blast_presale::blast_presale_package::version_for_testing(&mut ctx);
    let mut policy = empty_policy(&mut ctx);
    let partner = new_partner(&mut ctx);

    package_version.set_version_for_testing(2);
    policy.add_partner(&package_version, &fee_admin(), &partner);
    abort
}

// === Test Helpers ===

fun allowing_nothing(): CreationPolicy {
    let mut ctx = tx_context::dummy();

    creation_policy::new_for_testing(&mut ctx)
}

fun allowing<Quote, MigrationWitness>(): CreationPolicy {
    let mut ctx = tx_context::dummy();

    creation_policy::allowing_for_testing<Quote, MigrationWitness>(&mut ctx)
}

/// An empty policy, from `ctx` so later objects get distinct IDs.
fun empty_policy(ctx: &mut TxContext): CreationPolicy {
    creation_policy::new_for_testing(ctx)
}

/// A registered Blast partner whose cut of Blast's fee is in force.
fun new_partner(ctx: &mut TxContext): Partner {
    partners::new_for_testing(PARTNER, PARTNER_CUT_BPS, ctx)
}

fun clock_at(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(timestamp_ms);

    clock
}

/// A policy whose administrator added a partner and removed it at `REMOVED_AT_MS`, and the
/// partner's ID.
fun policy_with_removed_partner(ctx: &mut TxContext): (CreationPolicy, ID) {
    let package_version = blast_presale::blast_presale_package::version_for_testing(ctx);
    let (result_0, result_1) = {
        let mut policy = empty_policy(ctx);
        let partner = new_partner(ctx);
        let clock = clock_at(REMOVED_AT_MS, ctx);
        let partner_id = object::id(&partner);
        policy.add_partner(&package_version, &fee_admin(), &partner);

        policy.remove_partner(&package_version, &fee_admin(), &partner, &clock);

        destroy(partner);
        clock.destroy_for_testing();
        (policy, partner_id)
    };
    std::unit_test::destroy(package_version);
    (result_0, result_1)
}

/// Aborts unless the policy accepts `partner_id` at `timestamp_ms`.
fun assert_partner_at(policy: &CreationPolicy, partner_id: ID, timestamp_ms: u64) {
    let clock = clock_at(timestamp_ms, &mut tx_context::dummy());
    policy.assert_partner(partner_id, &clock);
    clock.destroy_for_testing();
}

fun listing_admin(): AdminWitness<ListingAdmin> {
    blast_acl::witness_for_testing()
}

fun venue_admin(): AdminWitness<VenueAdmin> {
    blast_acl::witness_for_testing()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun type_name<T>(): TypeName {
    type_name::with_original_ids<T>()
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, delayed_set::{MemberRemoved, SetApplied}};

use blast_core::blast_domain::{VenueAdmin, FeeAdmin, ListingAdmin};

use blast_partners::{
    blast_partners::{Self as partners, Partner},
    partner_list::{PartnerAdded, PartnerRemoved}
};

use blast_presale::{creation_policy::{Self, CreationPolicy, VenueKey}, events::QuoteAllowed};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario};

use fun assert_partner_at as CreationPolicy.assert_partner_at;
