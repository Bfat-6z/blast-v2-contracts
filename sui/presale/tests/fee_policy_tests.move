// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::fee_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;
const TREASURY: address = @0x7EA5;

// === Tests ===

#[test]
/// Publication shares the map fee policy and uses the genesis treasury.
fun publication_shares_the_map_fee_policy_paying_the_genesis_treasury() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    fee_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<FeePolicy>();
    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(200, 100, 1_500, 1_500));
    assert_eq!(policy.destination(), @blast_treasury);

    test_scenario::return_shared(policy);
    scenario.end();
}

#[test]
/// Every rate accepts its maximum and returns to zero.
fun the_admin_sets_maximum_and_zero_rates() {
    let package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    policy.set_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(9_999),
        bps::new(9_998),
        bps::new(10_000),
        bps::new(10_000),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(9_999, 9_998, 10_000, 10_000));
    let (owner, _, previous, applied, _) = last_event<
        DelayedApplied<FeesKey, ProtocolFees>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(previous, fee_policy::protocol_fees_for_testing(0, 0, 0, 0));
    assert_eq!(applied, fee_policy::protocol_fees_for_testing(9_999, 9_998, 10_000, 10_000));

    policy.set_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(0),
        bps::new(0),
        bps::new(0),
        bps::new(0),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(0, 0, 0, 0));

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
/// Blast cannot take the whole raise, which would leave the pool no Quote.
fun the_raise_share_must_stay_below_full() {
    set_fees_for_testing(10_000, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
/// The sale and LP allocations each need at least one BPS of the supply.
fun the_token_share_must_leave_two_bps() {
    set_fees_for_testing(0, 9_999, 0, 0);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun a_fee_update_must_change_the_rates() {
    set_fees_for_testing(0, 0, 0, 0);
}

#[test]
/// A vault's LP-rate change keeps the raise and token rates it was snapshotted with.
fun lp_fee_rates_change_alone() {
    assert_eq!(
        fee_policy::protocol_fees_for_testing(100, 200, 300, 400).with_lp_fees(
            bps::new(0),
            bps::new(10_000),
        ),
        fee_policy::protocol_fees_for_testing(100, 200, 0, 10_000),
    );
}

#[test]
/// The administrator redirects every later payout.
fun the_admin_sets_the_destination() {
    let package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    policy.set_destination_for_testing(&package_version, &treasury_admin(), TREASURY, &mut sui::tx_context::dummy());

    assert_eq!(policy.destination(), TREASURY);
    let (owner, _, _, applied, _) = last_event<
        DelayedApplied<DestinationKey, address>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(applied, TREASURY);

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = fee_policy::EInvalidDestination,
    location = blast_presale::fee_policy,
)]
fun the_destination_cannot_be_the_zero_address() {
    set_destination_for_testing(@0x0);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun a_destination_update_must_change_the_address() {
    let package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();
    policy.set_destination_for_testing(&package_version, &treasury_admin(), TREASURY, &mut sui::tx_context::dummy());

    policy.set_destination_for_testing(&package_version, &treasury_admin(), TREASURY, &mut sui::tx_context::dummy());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_cannot_redirect_fees() {
    let mut package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    package_version.set_for_testing(2);
    policy.set_destination_for_testing(&package_version, &treasury_admin(), TREASURY, &mut sui::tx_context::dummy());

    assert_eq!(policy.destination(), TREASURY);
    let (owner, _, _, applied, _) = last_event<
        DelayedApplied<DestinationKey, address>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(applied, TREASURY);

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_cannot_set_fees() {
    let mut package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    package_version.set_for_testing(2);
    policy.set_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(9_999),
        bps::new(9_998),
        bps::new(10_000),
        bps::new(10_000),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(9_999, 9_998, 10_000, 10_000));
    let (owner, _, previous, applied, _) = last_event<
        DelayedApplied<FeesKey, ProtocolFees>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(previous, fee_policy::protocol_fees_for_testing(0, 0, 0, 0));
    assert_eq!(applied, fee_policy::protocol_fees_for_testing(9_999, 9_998, 10_000, 10_000));

    policy.set_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(0),
        bps::new(0),
        bps::new(0),
        bps::new(0),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(0, 0, 0, 0));

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

// === Test Helpers ===

/// A fresh policy: zero rates, paying the dummy context's sender.
fun new_policy(): FeePolicy {
    let mut ctx = tx_context::dummy();

    fee_policy::new_zero_fees_for_testing(&mut ctx)
}

fun set_fees_for_testing(
    raise_bps: u64,
    token_bps: u64,
    lp_fee_meme_bps: u64,
    lp_fee_quote_bps: u64
) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    policy.set_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(raise_bps),
        bps::new(token_bps),
        bps::new(lp_fee_meme_bps),
        bps::new(lp_fee_quote_bps),
        &mut sui::tx_context::dummy()
    );

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

fun set_destination_for_testing(destination: address) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    policy.set_destination_for_testing(&package_version, &treasury_admin(), destination, &mut sui::tx_context::dummy());

    policy.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, delayed::DelayedApplied};

use blast_presale::{
    blast_presale_domain::{FeeAdmin, TreasuryAdmin},
    bps,
    fee_policy::{Self, DestinationKey, FeePolicy, FeesKey, ProtocolFees}
};

use std::unit_test::assert_eq;

use sui::{event, test_scenario};
