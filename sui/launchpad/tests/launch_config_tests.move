// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 250;

const MEME_DECIMALS: u8 = 9;

const PARTNER: address = @0x9A27;

/// When the fixture clock removes a partner.
const NOW_AT_MS: u64 = 1_000;

/// The applied delay of every setting in `launch_config::new_zero_fees_for_testing`.
const DELAY_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct TEST_QUOTE() has drop;

public struct TestVenue() has drop;

public struct QUOTE<phantom Marker>() has drop;

public struct Q0() has drop;

public struct Q1() has drop;

public struct Q2() has drop;

public struct Q3() has drop;

public struct Q4() has drop;

public struct Q5() has drop;

public struct Q6() has drop;

public struct Q7() has drop;

public struct Q8() has drop;

public struct Q9() has drop;

public struct Q10() has drop;

public struct Q11() has drop;

public struct Q12() has drop;

public struct Q13() has drop;

public struct Q14() has drop;

public struct Q15() has drop;

public struct Q16() has drop;

/// Package-initialization facts only; carries no ACL or admin state.
public struct InitFixture {
    scenario: Scenario,
    config: LaunchConfig,
}

/// Cold-policy administration under each setter's own role.
public struct ConfigFixture {
    scenario: Scenario,
    package_version: PackageVersion<BLAST_FUN>,
    config: LaunchConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun package_init_uses_map_fees_with_six_and_nine_decimals() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (quote_fee_bps, meme_fee_bps) = f.config.rate_defaults_for_testing();

        assert_eq!(quote_fee_bps, 150);
        assert_eq!(meme_fee_bps, 0);
        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(f.config.allowed_venue_count_for_testing(), 0);
        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 2);
        assert_eq!(f.config.creation_fee(), 0);
        assert_eq!(
            f.config.protocol_allocation(),
            allocation::protocol_allocation(bps::new(250), bps::new(150)),
        );
        assert_eq!(f.config.protocol_lp_fees_values(), vector[1_500, 1_500]);
    });

    fixture.end();
}

#[test]
fun protocol_allocation_updates_and_emits_rates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation_for_testing(500, 250);

        let mut expected = u64_bytes(500);
        expected.append(u64_bytes(250));

        assert_eq!(bcs::to_bytes(&applied_one<ProtocolAllocationKey, ProtocolAllocation>()), expected);
        assert_eq!(
            f.config.protocol_allocation(),
            allocation::protocol_allocation(bps::new(500), bps::new(250)),
        );
    });

    fixture.end();
}

#[test]
fun protocol_allocation_accepts_zero_shares() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation_for_testing(1, 1);
        f.set_protocol_allocation_for_testing(0, 0);

        assert_eq!(
            f.config.protocol_allocation(),
            allocation::protocol_allocation(bps::new(0), bps::new(0)),
        );
    });

    fixture.end();
}

#[test]
fun protocol_allocation_accepts_its_maximum_for_each_asset() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation_for_testing(1_000, 1_000);

        assert_eq!(
            f.config.protocol_allocation(),
            allocation::protocol_allocation(bps::new(1_000), bps::new(1_000)),
        );
    });

    fixture.end();
}

#[test]
fun protocol_allocation_can_be_updated_for_future_launches() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_allocation_for_testing(1, 1);
        f.set_protocol_allocation_for_testing(2, 3);

        assert_eq!(
            f.config.protocol_allocation(),
            allocation::protocol_allocation(bps::new(2), bps::new(3)),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun protocol_allocation_rejects_an_unchanged_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation_for_testing(0, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::allocation,
    ),
]
fun protocol_allocation_rejects_meme_one_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation_for_testing(1_001, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidProtocolAllocation,
        location = blast_fun::allocation,
    ),
]
fun protocol_allocation_rejects_quote_one_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_allocation_for_testing(0, 1_001));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_protocol_allocation_before_its_bounds() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_version_for_testing(2);

        f.set_protocol_allocation_for_testing(10_000, 10_000);
    });

    fixture.end();
}

// --- Blast's LP-fee share ---

#[test]
fun protocol_lp_fees_update_and_emit_rates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_lp_fees_for_testing(1_200, 900);

        let mut expected = u64_bytes(1_200);
        expected.append(u64_bytes(900));

        assert_eq!(bcs::to_bytes(&applied_one<ProtocolLpFeesKey, ProtocolLpFees>()), expected);
        assert_eq!(f.config.protocol_lp_fees_values(), vector[1_200, 900]);
    });

    fixture.end();
}

#[test]
fun protocol_lp_fees_accept_their_maximum_for_each_asset() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_lp_fees_for_testing(3_000, 3_000);

        assert_eq!(f.config.protocol_lp_fees_values(), vector[3_000, 3_000]);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun protocol_lp_fees_reject_an_unchanged_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_lp_fees_for_testing(0, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLpFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun protocol_lp_fees_reject_meme_one_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_lp_fees_for_testing(3_001, 0));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLpFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun protocol_lp_fees_reject_quote_one_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| f.set_protocol_lp_fees_for_testing(0, 3_001));

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_protocol_lp_fees_before_their_bounds() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_version_for_testing(2);

        f.set_protocol_lp_fees_for_testing(10_000, 10_000);
    });

    fixture.end();
}

#[test]
fun a_protocol_lp_fee_change_waits_its_applied_delay() {
    let mut fixture = start_with_delays();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_protocol_lp_fees(1_200, 900);
        f.clock.set_for_testing(NOW_AT_MS + DELAY_MS - 1);

        assert_eq!(f.config.protocol_lp_fees_values(), vector[0, 0]);

        f.clock.set_for_testing(NOW_AT_MS + DELAY_MS);
        f.config.apply_protocol_lp_fees(&f.package_version, &f.clock);

        assert_eq!(f.config.protocol_lp_fees_values(), vector[1_200, 900]);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_protocol_lp_fee_change_cannot_apply_one_millisecond_early() {
    let mut fixture = start_with_delays();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_protocol_lp_fees(1_200, 900);
        f.clock.set_for_testing(NOW_AT_MS + DELAY_MS - 1);

        f.config.apply_protocol_lp_fees(&f.package_version, &f.clock);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun a_cancelled_protocol_lp_fee_change_never_applies() {
    let mut fixture = start_with_delays();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.schedule_protocol_lp_fees(1_200, 900);
        f.config.cancel_protocol_lp_fees(&f.package_version, &blast_acl::witness_for_testing<CancelAdmin>());
        f.clock.set_for_testing(NOW_AT_MS + DELAY_MS);

        f.config.apply_protocol_lp_fees(&f.package_version, &f.clock);
    });

    fixture.end();
}

#[test]
fun admin_removes_and_readds_decimal_precision_for_future_tickets() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, false);

        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&collect_one<MemeDecimalsSet>()), vector[6, 0]);

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
        let set = collect<MemeDecimalsSet>();

        assert_eq!(f.config.allowed_meme_decimals_count_for_testing(), 2);
        assert_eq!(set.length(), 2);
        assert_eq!(bcs::to_bytes(&set[1]), vector[6, 1]);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyAlreadyExists,
        location = sui::vec_set,
    ),
]
fun allowing_an_admitted_decimal_rejects_the_unchanged_set() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyDoesNotExist,
        location = sui::vec_set,
    ),
]
fun disallowing_an_unlisted_decimal_rejects_the_unchanged_set() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 8, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_decimals_before_the_unchanged_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();
        f.package_version.set_version_for_testing(2);

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EDecimalsNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_disallowed_decimals() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_venue();
        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, MEME_DECIMALS, false);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);
    });

    fixture.end();
}

#[test]
fun admin_allows_a_venue_for_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_venue();

        let (quote_fee_bps, meme_fee_bps) = f
            .config
            .snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);

        assert_eq!(quote_fee_bps.value(), 0);
        assert_eq!(meme_fee_bps.value(), 0);
    });

    fixture.end();
}

#[test]
fun admin_allows_quote_for_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_venue();

        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 1);
        assert_eq!(bcs::to_bytes(&collect_one<QuoteSet<TEST_QUOTE>>()), quote_set_bytes(true));
    });

    fixture.end();
}

#[test]
fun disallowing_a_quote_removes_it_from_future_launches() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);

        let set = collect<QuoteSet<TEST_QUOTE>>();

        assert_eq!(f.config.allowed_quote_count_for_testing(), 0);
        assert_eq!(set.length(), 2);
        assert_eq!(bcs::to_bytes(&set[1]), quote_set_bytes(false));
    });

    fixture.end();
}

#[test]
fun admin_can_readd_a_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.allow_test_venue();

        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 1);
    });

    fixture.end();
}

#[test]
fun many_quotes_can_be_admitted() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<QUOTE<Q0>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q1>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q2>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q3>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q4>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q5>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q6>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q7>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q8>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q9>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q10>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q11>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q12>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q13>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q14>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q15>>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<QUOTE<Q16>>(&f.package_version, &admin_witness, true);

        assert_eq!(f.config.allowed_quote_count_for_testing(), 17);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyAlreadyExists,
        location = sui::vec_set,
    ),
]
fun allowing_an_admitted_quote_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = sui::vec_set::EKeyDoesNotExist,
        location = sui::vec_set,
    ),
]
fun disallowing_an_unlisted_quote_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_quote_before_the_set_update() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();
        f.package_version.set_version_for_testing(2);

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EQuoteNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_disallowed_quote() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, false);
        f.allow_test_venue();
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);
    });

    fixture.end();
}

#[test]
fun admin_sets_trade_fees_for_future_launch_snapshots() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &listing_admin(), true);
        f.allow_test_venue();
        f
            .config
            .set_trade_fees_for_testing(
                &f.package_version,
                &fee_admin(),
                bps::new(QUOTE_FEE_BPS),
                bps::new(MEME_FEE_BPS),
             f.ctx!());

        let (quote_fee_bps, meme_fee_bps) = f
            .config
            .snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);
        let mut expected = u64_bytes(QUOTE_FEE_BPS);
        expected.append(u64_bytes(MEME_FEE_BPS));

        assert_eq!(quote_fee_bps.value(), QUOTE_FEE_BPS);
        assert_eq!(meme_fee_bps.value(), MEME_FEE_BPS);
        assert_eq!(bcs::to_bytes(&applied_one<TradeFeesKey, TradeFees>()), expected);
    });

    fixture.end();
}

#[test]
fun trade_fees_accept_zero_and_launch_ceiling_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();

        f
            .config
            .set_trade_fees_for_testing(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_trade_fee_bps!()),
                bps::new(constants::max_trade_fee_bps!()),
             f.ctx!());
        f.config.set_trade_fees_for_testing(&f.package_version, &admin_witness, bps::new(0), bps::new(0), f.ctx!());
        f.config.set_trade_fees_for_testing(&f.package_version, &admin_witness, bps::new(0), bps::new(1), f.ctx!());

        let (quote_fee_bps, meme_fee_bps) = f.config.rate_defaults_for_testing();

        assert_eq!(applied<TradeFeesKey, TradeFees>().length(), 3);
        assert_eq!(quote_fee_bps, 0);
        assert_eq!(meme_fee_bps, 1);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidTradeFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun trade_fees_reject_quote_rate_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();

        f
            .config
            .set_trade_fees_for_testing(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_trade_fee_bps!() + 1),
                bps::new(0),
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidTradeFeeBps,
        location = blast_fun::launch_config,
    ),
]
fun trade_fees_reject_meme_rate_above_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();

        f
            .config
            .set_trade_fees_for_testing(
                &f.package_version,
                &admin_witness,
                bps::new(0),
                bps::new(constants::max_trade_fee_bps!() + 1),
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EUnchanged,
        location = blast_admin::delayed,
    ),
]
fun trade_fees_reject_unchanged_pair() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();

        f.config.set_trade_fees_for_testing(&f.package_version, &admin_witness, bps::new(0), bps::new(0), f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_trade_fees_before_their_bounds() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();
        f.package_version.set_version_for_testing(2);

        f
            .config
            .set_trade_fees_for_testing(
                &f.package_version,
                &admin_witness,
                bps::new(constants::max_trade_fee_bps!() + 1),
                bps::new(0),
             f.ctx!());
    });

    fixture.end();
}

#[test]
fun admin_allows_a_venue_and_the_primitive_records_its_original_type_name() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.allow_test_venue();

        let admissions = event::events_by_type<SetApplied<VenueKey, TypeName>>();
        assert_eq!(admissions.length(), 1);
        let (owner, _, change, _) = admissions[0].set_applied_fields();

        assert_eq!(f.config.allowed_venue_count_for_testing(), 1);
        assert_eq!(owner, object::id(&f.config));
        assert_eq!(change.member(), option::some(test_venue()));
    });

    fixture.end();
}

#[test]
fun disallowing_a_venue_does_not_change_an_existing_launch_snapshot() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &listing_admin(), true);
        f.allow_test_venue();
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);

        f
            .config
            .set_venue_allowed_for_testing<TestVenue>(
                &f.package_version,
                &venue_admin(),
                false,
             f.ctx!());

        let removed = event::events_by_type<MemberRemoved<VenueKey, TypeName>>();
        assert_eq!(removed.length(), 1);
        let (_, _, member) = removed[0].member_removed_fields();

        assert_eq!(f.config.allowed_venue_count_for_testing(), 0);
        assert_eq!(member, test_venue());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EUnchanged,
        location = blast_admin::delayed_set,
    ),
]
fun disallowing_a_venue_rejects_an_unlisted_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        f
            .config
            .set_venue_allowed_for_testing<TestVenue>(
                &f.package_version,
                &admin_witness,
                false,
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EUnchanged,
        location = blast_admin::delayed_set,
    ),
]
fun allowing_a_venue_rejects_a_duplicate_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.allow_test_venue();
        f.allow_test_venue();
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidVenue,
        location = blast_fun::launch_config,
    ),
]
fun allowing_a_venue_rejects_a_primitive_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        // The primitive check runs before the origin lookup, which no primitive type supports.
        f.config.set_venue_allowed_for_testing<bool>(&f.package_version, &admin_witness, true, f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidVenue,
        location = blast_fun::launch_config,
    ),
]
fun allowing_a_venue_rejects_a_vector_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        // The primitive check runs before the origin lookup, which no primitive type supports.
        f
            .config
            .set_venue_allowed_for_testing<vector<u8>>(
                &f.package_version,
                &admin_witness,
                true,
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidVenue,
        location = blast_fun::launch_config,
    ),
]
fun allowing_a_venue_rejects_a_standard_library_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        f
            .config
            .set_venue_allowed_for_testing<String>(
                &f.package_version,
                &admin_witness,
                true,
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidVenue,
        location = blast_fun::launch_config,
    ),
]
fun allowing_a_venue_rejects_a_sui_framework_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        f
            .config
            .set_venue_allowed_for_testing<ID>(
                &f.package_version,
                &admin_witness,
                true,
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EUnchanged,
        location = blast_admin::delayed_set,
    ),
]
fun disallowing_a_framework_type_reports_it_as_unlisted() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();

        f
            .config
            .set_venue_allowed_for_testing<ID>(
                &f.package_version,
                &admin_witness,
                false,
             f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EVersionMismatch,
        location = blast_admin::package_version,
    ),
]
fun stale_package_version_rejects_a_venue_before_its_type_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = venue_admin();
        f.package_version.set_version_for_testing(2);

        f.config.set_venue_allowed_for_testing<bool>(&f.package_version, &admin_witness, true, f.ctx!());
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EVenueNotAllowed,
        location = blast_fun::launch_config,
    ),
]
fun launch_snapshot_rejects_an_unlisted_venue() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = listing_admin();

        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &admin_witness, true);
        let (_, _) = f.config.snapshot_for_launch<TEST_QUOTE>(test_venue(), MEME_DECIMALS);
    });

    fixture.end();
}

// --- Creation fee ---

#[test]
fun admin_sets_the_creation_fee_and_it_emits_the_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee_for_testing(2_000_000_000);

        assert_eq!(f.config.creation_fee(), 2_000_000_000);
        assert_eq!(
            bcs::to_bytes(&applied_one<CreationFeeKey, u64>()),
            bcs::to_bytes(&2_000_000_000u64),
        );
    });

    fixture.end();
}

#[test]
fun creation_fee_accepts_its_ten_sui_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee_for_testing(10_000_000_000);

        assert_eq!(f.config.creation_fee(), 10_000_000_000);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreationFee, location = blast_fun::launch_config)]
fun creation_fee_rejects_one_mist_above_the_maximum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee_for_testing(10_000_000_001);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun creation_fee_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee_for_testing(0);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun creation_fee_checks_the_version_before_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_version_for_testing(2);

        f.set_creation_fee_for_testing(0);
    });

    fixture.end();
}

// --- Partners ---

#[test]
fun an_added_partner_is_accepted_at_once() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();

        f.add_partner(&partner);

        f.assert_partner_at(object::id(&partner), NOW_AT_MS);
        assert_eq!(
            bcs::to_bytes(&collect_one<PartnerAdded>()),
            partner_event_bytes(&f.config, object::id(&partner)),
        );
        destroy(partner);
    });

    fixture.end();
}

#[test]
/// A removed partner stays accepted for exactly the partner delay.
fun a_removed_partner_stays_accepted_for_the_partner_delay() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        let partner_id = object::id(&partner);
        f.add_partner(&partner);

        f.remove_partner(&partner);

        f.assert_partner_at(partner_id, NOW_AT_MS + partners::delay_ms() - 1);
        let mut expected = partner_event_bytes(&f.config, partner_id);
        expected.append(bcs::to_bytes(&(NOW_AT_MS + partners::delay_ms())));
        assert_eq!(bcs::to_bytes(&collect_one<PartnerRemoved>()), expected);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_partners::errors::EPartnerNotAccepted, location = blast_partners::partner_list)]
fun a_removed_partner_is_refused_once_its_delay_ends() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.assert_partner_at(object::id(&partner), NOW_AT_MS + partners::delay_ms());
        destroy(partner);
    });

    fixture.end();
}

#[test]
/// Adding a partner whose removal is pending cancels the removal.
fun adding_a_removed_partner_accepts_it_again() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.add_partner(&partner);

        f.assert_partner_at(object::id(&partner), std::u64::max_value!() - 1);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::partner_list)]
fun adding_an_accepted_partner_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);

        f.add_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_partners::errors::EUnchanged, location = blast_partners::partner_list)]
fun removing_a_partner_twice_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.remove_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_partners::errors::EPartnerNotAccepted, location = blast_partners::partner_list)]
fun removing_an_unknown_partner_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();

        f.remove_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun adding_a_partner_checks_the_version_first() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.package_version.set_version_for_testing(2);

        f.add_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun removing_a_partner_checks_the_version_before_the_list() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.package_version.set_version_for_testing(2);

        f.remove_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun config_ctx($fixture: &mut ConfigFixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

/// The venue a ticket from the test venue hands to launch intake.
fun test_venue(): TypeName {
    type_name::with_original_ids<TestVenue>()
}

/// Serializes one protocol constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

/// Expected `QuoteSet` bytes for the test quote.
fun quote_set_bytes(allowed: bool): vector<u8> {
    bcs::to_bytes(&allowed)
}

fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<T>()
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = collect<T>();
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
}

/// The values the primitive applied to the setting keyed by `K`, in order.
fun applied<K: copy + drop + store, T: copy + drop + store>(): vector<T> {
    event::events_by_type<DelayedApplied<K, T>>().map!(|applied| {
        let (_, _, _, value, _) = applied.delayed_applied_fields();
        value
    })
}

fun applied_one<K: copy + drop + store, T: copy + drop + store>(): T {
    let mut values = applied<K, T>();
    assert_eq!(values.length(), 1);
    values.pop_back()
}

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    launch_config::init_for_testing(scenario.ctx());

    // Only the primitive's creation records of the five delayed operations.
    assert_eq!(event::num_events(), 5);

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<LaunchConfig>();

    InitFixture { scenario, config }
}

/// A configuration whose every change waits `DELAY_MS`, with the clock at `NOW_AT_MS`.
fun start_with_delays(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::version_for_testing(scenario.ctx());
    let config = launch_config::new_zero_fees_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_AT_MS);

    ConfigFixture { scenario, package_version, config, clock }
}

/// The shared configuration exactly as package initialization leaves it.
fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::version_for_testing(scenario.ctx());
    launch_config::init_zero_fees_for_testing(scenario.ctx());

    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_AT_MS);

    scenario.next_tx(PROTOCOL_ADMIN);
    let config = scenario.take_shared<LaunchConfig>();

    ConfigFixture { scenario, package_version, config, clock }
}

fun listing_admin(): AdminWitness<ListingAdmin> {
    blast_acl::witness_for_testing()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun venue_admin(): AdminWitness<VenueAdmin> {
    blast_acl::witness_for_testing()
}

/// Sets Blast's allocation as the treasury admin.
fun set_protocol_allocation_for_testing(
    self: &mut ConfigFixture,
    meme_bps: u64,
    quote_bps: u64,
) {
    let admin_witness = blast_acl::witness_for_testing<TreasuryAdmin>();

    self
        .config
        .set_protocol_allocation_for_testing(
            &self.package_version,
            &admin_witness,
            bps::new(meme_bps),
            bps::new(quote_bps),
         self.ctx!());
}

/// Sets Blast's LP-fee share as the fee admin.
fun set_protocol_lp_fees_for_testing(self: &mut ConfigFixture, meme_bps: u64, quote_bps: u64) {
    self
        .config
        .set_protocol_lp_fees_for_testing(
            &self.package_version,
            &fee_admin(),
            bps::new(meme_bps),
            bps::new(quote_bps),
            self.ctx!(),
        );
}

/// Schedules Blast's LP-fee share as the fee admin, keeping the applied delay.
fun schedule_protocol_lp_fees(self: &mut ConfigFixture, meme_bps: u64, quote_bps: u64) {
    self
        .config
        .schedule_protocol_lp_fees(
            &self.package_version,
            &fee_admin(),
            bps::new(meme_bps),
            bps::new(quote_bps),
            DELAY_MS,
            &self.clock,
        );
}

/// Blast's applied LP-fee share, Meme then Quote, in basis points.
fun protocol_lp_fees_values(self: &LaunchConfig): vector<u64> {
    let (meme_bps, quote_bps) = self.protocol_lp_fees();

    vector[meme_bps.value(), quote_bps.value()]
}

/// Admits the test venue as the adapter admin.
fun allow_test_venue(self: &mut ConfigFixture) {
    self
        .config
        .set_venue_allowed_for_testing<TestVenue>(
            &self.package_version,
            &venue_admin(),
            true,
         self.ctx!());
}

fun set_creation_fee_for_testing(self: &mut ConfigFixture, creation_fee: u64) {
    self.config.set_creation_fee_for_testing(&self.package_version, &fee_admin(), creation_fee, self.ctx!());
}

fun new_partner(self: &mut ConfigFixture): Partner {
    partners::new_for_testing(PARTNER, 4_000, self.ctx!())
}

fun add_partner(self: &mut ConfigFixture, partner: &Partner) {
    self.config.add_partner(&self.package_version, &fee_admin(), partner);
}

fun remove_partner(self: &mut ConfigFixture, partner: &Partner) {
    self.config.remove_partner(&self.package_version, &fee_admin(), partner, &self.clock);
}

/// Checks the configuration accepts `partner_id` at `at_ms`, on a clock of its own.
fun assert_partner_at(self: &mut ConfigFixture, partner_id: ID, at_ms: u64) {
    let mut clock = clock::create_for_testing(self.ctx!());
    clock.set_for_testing(at_ms);
    self.config.assert_partner(partner_id, &clock);
    destroy(clock);
}

/// The leading bytes of a partner-list event of the configuration's list: its owner, the
/// configuration, then the partner.
fun partner_event_bytes(config: &LaunchConfig, partner_id: ID): vector<u8> {
    let mut expected = bcs::to_bytes(&object::id(config));
    expected.append(bcs::to_bytes(&partner_id));
    expected
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    delayed::DelayedApplied,
    delayed_set::{MemberRemoved, SetApplied},
    package_version::PackageVersion
};

use blast_core::{bps, blast_domain::{VenueAdmin, CancelAdmin, FeeAdmin, ListingAdmin, TreasuryAdmin}};

use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    constants,
    events::{MemeDecimalsSet, QuoteSet},
    launch_config::{
        Self,
        CreationFeeKey,
        LaunchConfig,
        ProtocolAllocationKey,
        ProtocolLpFees,
        ProtocolLpFeesKey,
        TradeFees,
        TradeFeesKey,
        VenueKey,
    },
    blast_fun::{Self as package_version, BLAST_FUN},
};

use blast_partners::{
    blast_partners::{Self as partners, Partner},
    partner_list::{PartnerAdded, PartnerRemoved}
};

use std::{bcs, string::String, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun config_ctx as ConfigFixture.ctx;

use fun protocol_lp_fees_values as LaunchConfig.protocol_lp_fees_values;
