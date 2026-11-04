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
        bps::new(1_000),
        bps::new(1_000),
        bps::new(3_000),
        bps::new(3_000),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(1_000, 1_000, 3_000, 3_000));
    let (owner, _, previous, applied, _) = last_event<
        DelayedApplied<FeesKey, ProtocolFees>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(previous, fee_policy::protocol_fees_for_testing(0, 0, 0, 0));
    assert_eq!(applied, fee_policy::protocol_fees_for_testing(1_000, 1_000, 3_000, 3_000));

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
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidFees,
    location = blast_presale::fee_policy,
)]
/// Blast's raise share is at most 1,000 BPS.
fun the_raise_share_is_capped() {
    set_fees_for_testing(1_001, 0, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidFees,
    location = blast_presale::fee_policy,
)]
/// Blast's token share is at most 1,000 BPS.
fun the_token_share_is_capped() {
    set_fees_for_testing(0, 1_001, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidFees,
    location = blast_presale::fee_policy,
)]
/// Blast's Meme LP-fee share is at most 3,000 BPS.
fun the_meme_lp_fee_share_is_capped() {
    set_fees_for_testing(0, 0, 3_001, 0);
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidFees,
    location = blast_presale::fee_policy,
)]
/// Blast's Quote LP-fee share is at most 3,000 BPS.
fun the_quote_lp_fee_share_is_capped() {
    set_fees_for_testing(0, 0, 0, 3_001);
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
            bps::new(3_000),
        ),
        fee_policy::protocol_fees_for_testing(100, 200, 0, 3_000),
    );
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EInvalidFees,
    location = blast_presale::fee_policy,
)]
/// A vault's LP-rate change is held to the same maximum as the policy.
fun lp_fee_rate_changes_are_capped() {
    fee_policy::protocol_fees_for_testing(100, 200, 300, 400).with_lp_fees(
        bps::new(3_001),
        bps::new(0),
    );

    abort
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
    abort_code = blast_presale::errors::EInvalidDestination,
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
    abort_code = blast_admin::errors::EUnchanged,
    location = blast_admin::delayed,
)]
fun a_destination_update_must_change_the_address_or_notice() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let mut policy = new_policy();
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    let admin = treasury_admin();
    policy.schedule_destination(&package_version, &admin, @0xB0B, 0, &clock);
    clock.set_for_testing(172_800_000);
    policy.apply_destination(&package_version, &clock);

    policy.schedule_destination(&package_version, &admin, @0xB0B, 0, &clock);

    clock.destroy_for_testing();
    policy.destroy_for_testing();
    std::unit_test::destroy(package_version);
}

#[test]
fun destination_notice_can_change_without_redirecting_fees() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let mut policy = new_policy();
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    let admin = treasury_admin();
    policy.schedule_destination(&package_version, &admin, @0xB0B, 0, &clock);
    clock.set_for_testing(172_800_000);
    policy.apply_destination(&package_version, &clock);
    policy.schedule_destination(&package_version, &admin, @0xB0B, 10, &clock);
    policy.apply_destination(&package_version, &clock);

    policy.schedule_destination(&package_version, &admin, @0xCAFE, 0, &clock);
    clock.set_for_testing(172_800_010);
    policy.apply_destination(&package_version, &clock);
    assert_eq!(policy.destination(), @0xCAFE);

    clock.destroy_for_testing();
    policy.destroy_for_testing();
    std::unit_test::destroy(package_version);
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
        bps::new(1_000),
        bps::new(1_000),
        bps::new(3_000),
        bps::new(3_000),
     &mut sui::tx_context::dummy());

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(1_000, 1_000, 3_000, 3_000));
    let (owner, _, previous, applied, _) = last_event<
        DelayedApplied<FeesKey, ProtocolFees>,
    >().delayed_applied_fields();
    assert_eq!(owner, object::id(&policy));
    assert_eq!(previous, fee_policy::protocol_fees_for_testing(0, 0, 0, 0));
    assert_eq!(applied, fee_policy::protocol_fees_for_testing(1_000, 1_000, 3_000, 3_000));

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
