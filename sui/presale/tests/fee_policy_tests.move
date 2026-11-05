// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::fee_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;

// === Tests ===

#[test]
/// Publication shares the fee policy with Blast's genesis rates.
fun publication_shares_the_fee_policy_with_the_genesis_rates() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    fee_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<FeePolicy>();
    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(200, 100, 1_500, 1_500));

    test_scenario::return_shared(policy);
    scenario.end();
}

#[test]
/// Every rate accepts its maximum and returns to zero.
fun the_admin_sets_maximum_and_zero_rates() {
    let package_version = blast_presale::blast_presale_package::version_for_testing(
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
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_version_cannot_set_fees() {
    let mut package_version = blast_presale::blast_presale_package::version_for_testing(
        &mut tx_context::dummy(),
    );
    let mut policy = new_policy();

    package_version.set_version_for_testing(2);
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

/// A fresh policy: zero rates under the 48-hour notice.
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
    let package_version = blast_presale::blast_presale_package::version_for_testing(
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

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, delayed::DelayedApplied};

use blast_core::{blast_domain::FeeAdmin, bps};

use blast_presale::fee_policy::{Self, FeePolicy, FeesKey, ProtocolFees};

use std::unit_test::assert_eq;

use sui::{event, test_scenario};
