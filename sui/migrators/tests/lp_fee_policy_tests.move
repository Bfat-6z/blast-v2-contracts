// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// LP-fee policy administration: the default pair, original-type per-coin pairs, the live protocol
/// destination, and the shares every collection reads live from them.
module blast_fun_migrators::lp_fee_policy_tests;

// === Test-Only Types ===

public struct MemeA has drop {}

public struct MemeB has drop {}

/// Publication-only setup; owns no administrator resources.
public struct InitFixture {
    scenario: Scenario,
    policy: LpFeePolicy,
}

/// Live policy administration under each setter's own role.
public struct PolicyFixture {
    scenario: Scenario,
    migrators_version: MigratorsVersion,
    policy: LpFeePolicy,
}

/// Independently encoded `SharePair` in ABI order.
public struct ExpectedPair has copy, drop {
    meme_bps: u64,
    quote_bps: u64,
}

// === Tests ===

#[test]
fun pending_override_and_delayed_clear_preserve_in_force_shares() {
    let mut fixture = start_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        f
            .policy
            .schedule_coin_shares<MemeA>(
                &f.migrators_version,
                &fee_admin(),
                bps::new(123),
                bps::new(456),
                &clock
            );
        f.assert_shares<MemeA>(0, 0);
        clock.set_for_testing(172_800_000);
        f.assert_shares<MemeA>(0, 0);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(123, 456);
        f
            .policy
            .schedule_clear_coin_shares<MemeA>(&f.migrators_version, &fee_admin(), &clock);
        f.assert_shares<MemeA>(123, 456);
        clock.set_for_testing(345_600_000);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(0, 0);

        destroy(clock);
    });
    fixture.end();
}


#[test]
fun publication_shares_one_fifteen_percent_policy() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (live_meme_bps, live_quote_bps) = f.policy.shares<MemeA>();
        assert_eq!(live_meme_bps.value(), 1_500);
        assert_eq!(live_quote_bps.value(), 1_500);
        let (default_meme_bps, default_quote_bps) = f.policy.default_shares_for_testing();
        assert_eq!(default_meme_bps.value(), 1_500);
        assert_eq!(default_quote_bps.value(), 1_500);
        assert!(f.policy.coin_shares_for_testing().value(&type_name::with_original_ids<MemeA>()).is_none());
    });

    fixture.end();
}

#[test]
fun publisher_is_the_initial_protocol_destination_until_redirected() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_eq!(f.policy.protocol_destination(), @blast_lp_fee_destination);
    });

    fixture.end();
}

#[test]
fun admin_redirects_the_protocol_destination_and_records_old_and_new() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.policy.set_protocol_destination_for_testing(&f.migrators_version, &admin, @0xCAFE, f.scenario.ctx());

        assert_eq!(f.policy.protocol_destination(), @0xCAFE);
        let events = event::events_by_type<DelayedApplied<ProtocolDestinationKey, address>>();
        assert_eq!(events.length(), 1);
        let (owner, _, previous_value, value, delay_ms) = events[0].delayed_applied_fields();
        assert_eq!(owner, object::id(&f.policy));
        assert_eq!(previous_value, PUBLISHER);
        assert_eq!(value, @0xCAFE);
        assert_eq!(delay_ms, 172_800_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun unchanged_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.policy.set_protocol_destination_for_testing(&f.migrators_version, &admin, PUBLISHER, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EInvalidProtocolDestination,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun zero_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.policy.set_protocol_destination_for_testing(&f.migrators_version, &admin, @0x0, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
fun active_admin_changes_independent_defaults_and_all_event_fields() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(2_000),
                bps::new(2_700),
                f.scenario.ctx()
            );

        f.assert_shares<MemeA>(2_000, 2_700);
        f.assert_shares<MemeB>(2_000, 2_700);
        assert_eq!(f.default_changes(), vector[default_change(pair(0, 0), pair(2_000, 2_700))]);
        assert!(f.coin_changes().is_empty());
    });

    fixture.end();
}

#[test]
fun changing_either_asset_alone_is_a_real_default_update() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(1),
                bps::new(0),
                f.scenario.ctx()
            );
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(1),
                bps::new(2),
                f.scenario.ctx()
            );

        f.assert_shares<MemeA>(1, 2);
        assert_eq!(
            f.default_changes(),
            vector[
                default_change(pair(0, 0), pair(1, 0)),
                default_change(pair(1, 0), pair(1, 2)),
            ],
        );
    });

    fixture.end();
}

#[test]
fun coin_pair_create_update_clear_readd_preserves_original_type_keys_and_event_history() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_default_shares_for_testing(version, &admin, bps::new(11), bps::new(22), f.scenario.ctx());
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(33), bps::new(44), f.scenario.ctx());
        f.policy.set_coin_shares_for_testing<MemeB>(version, &admin, bps::new(55), bps::new(66), f.scenario.ctx());
        f.assert_shares<MemeA>(33, 44);
        f.assert_shares<MemeB>(55, 66);
        assert!(f.has_override<MemeA>() && f.has_override<MemeB>());

        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(33), bps::new(77), f.scenario.ctx());
        f.assert_shares<MemeA>(33, 77);
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(88), bps::new(77), f.scenario.ctx());
        f.assert_shares<MemeA>(88, 77);
        f.policy.clear_coin_shares_for_testing<MemeA>(version, &admin, f.scenario.ctx());
        f.assert_shares<MemeA>(11, 22);
        f.assert_shares<MemeB>(55, 66);
        // Clearing removes the entry; only the other coin keeps one.
        assert!(!f.has_override<MemeA>() && f.has_override<MemeB>());

        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(99), bps::new(0), f.scenario.ctx());
        f.assert_shares<MemeA>(99, 0);
        assert!(f.has_override<MemeA>() && f.has_override<MemeB>());

        assert_eq!(f.default_changes(), vector[default_change(pair(0, 0), pair(11, 22))]);
        assert_eq!(
            f.coin_changes(),
            vector[
                coin_change<MemeA>(option::some(pair(33, 44))),
                coin_change<MemeB>(option::some(pair(55, 66))),
                coin_change<MemeA>(option::some(pair(33, 77))),
                coin_change<MemeA>(option::some(pair(88, 77))),
                coin_change<MemeA>(option::none()),
                coin_change<MemeA>(option::some(pair(99, 0))),
            ],
        );
    });

    fixture.end();
}

#[test]
fun a_coin_pair_equal_to_the_defaults_is_real_and_skips_later_default_changes() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(0), bps::new(0), f.scenario.ctx());
        f.policy.set_default_shares_for_testing(version, &admin, bps::new(1_234), bps::new(2_876), f.scenario.ctx());

        f.assert_shares<MemeA>(0, 0);
        f.assert_shares<MemeB>(1_234, 2_876);
        assert_eq!(f.coin_changes(), vector[coin_change<MemeA>(option::some(pair(0, 0)))]);
        assert_eq!(f.default_changes().length(), 1);
    });

    fixture.end();
}

#[test]
fun default_shares_read_the_default_pair_whatever_coin_pairs_are_set() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.assert_default_shares(0, 0);

        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(1_234),
                bps::new(2_876),
                f.scenario.ctx()
            );
        let version = &f.migrators_version;
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                version,
                &admin,
                bps::new(11),
                bps::new(22),
                f.scenario.ctx()
            );
        f.assert_default_shares(1_234, 2_876);
        f.assert_shares<MemeA>(11, 22);

        f
            .policy
            .clear_coin_shares_for_testing<MemeA>(&f.migrators_version, &admin, f.scenario.ctx());
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(5),
                bps::new(6),
                f.scenario.ctx()
            );
        f.assert_default_shares(5, 6);
        f.assert_shares<MemeA>(5, 6);
    });

    fixture.end();
}

#[test]
fun a_coin_pair_and_every_default_change_apply_to_the_very_next_read() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(3_000), bps::new(1), f.scenario.ctx());
        f.assert_shares<MemeA>(3_000, 1);
        f.assert_shares<MemeB>(0, 0);

        // A default change reaches every coin without its own pair at once, and no other.
        f.policy.set_default_shares_for_testing(version, &admin, bps::new(2), bps::new(3), f.scenario.ctx());
        f.assert_shares<MemeA>(3_000, 1);
        f.assert_shares<MemeB>(2, 3);

        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(4), bps::new(5), f.scenario.ctx());
        f.assert_shares<MemeA>(4, 5);

        // Clearing falls back to the defaults current at the clear, not those at the set.
        f.policy.clear_coin_shares_for_testing<MemeA>(version, &admin, f.scenario.ctx());
        f.assert_shares<MemeA>(2, 3);
        f.policy.set_default_shares_for_testing(version, &admin, bps::new(6), bps::new(7), f.scenario.ctx());
        f.assert_shares<MemeA>(6, 7);
        f.assert_shares<MemeB>(6, 7);
        assert!(!f.has_override<MemeA>());
    });

    fixture.end();
}

#[test]
fun both_assets_accept_zero_and_the_maximum_share_independently() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f
            .policy
            .set_default_shares_for_testing(
                version,
                &admin,
                bps::new(3_000),
                bps::new(0),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(3_000, 0);
        f
            .policy
            .set_default_shares_for_testing(
                version,
                &admin,
                bps::new(0),
                bps::new(3_000),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(0, 3_000);
        f
            .policy
            .set_default_shares_for_testing(
                version,
                &admin,
                bps::new(3_000),
                bps::new(3_000),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(3_000, 3_000);
        f
            .policy
            .set_default_shares_for_testing(
                version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(0, 0);

        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                version,
                &admin,
                bps::new(3_000),
                bps::new(0),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(3_000, 0);
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                version,
                &admin,
                bps::new(0),
                bps::new(3_000),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(0, 3_000);
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                version,
                &admin,
                bps::new(3_000),
                bps::new(3_000),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(3_000, 3_000);
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
        f.assert_shares<MemeA>(0, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = lp_fee_policy::EInvalidShares, location = blast_fun_migrators::lp_fee_policy)]
fun a_default_meme_share_above_the_cap_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.policy.set_default_shares_for_testing(
            &f.migrators_version,
            &fee_admin(),
            bps::new(3_001),
            bps::new(0),
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = lp_fee_policy::EInvalidShares, location = blast_fun_migrators::lp_fee_policy)]
fun a_default_quote_share_above_the_cap_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.policy.set_default_shares_for_testing(
            &f.migrators_version,
            &fee_admin(),
            bps::new(0),
            bps::new(3_001),
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = lp_fee_policy::EInvalidShares, location = blast_fun_migrators::lp_fee_policy)]
fun a_coin_meme_share_above_the_cap_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.policy.set_coin_shares_for_testing<MemeA>(
            &f.migrators_version,
            &fee_admin(),
            bps::new(3_001),
            bps::new(0),
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = lp_fee_policy::EInvalidShares, location = blast_fun_migrators::lp_fee_policy)]
fun a_coin_quote_share_above_the_cap_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.policy.set_coin_shares_for_testing<MemeA>(
            &f.migrators_version,
            &fee_admin(),
            bps::new(0),
            bps::new(3_001),
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed)]
fun unchanged_default_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_map)]
fun unchanged_coin_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(23), bps::new(45), f.scenario.ctx());
        f.policy.set_coin_shares_for_testing<MemeA>(version, &admin, bps::new(23), bps::new(45), f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_map)]
fun scheduling_clear_after_an_override_was_cleared_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        f.policy.schedule_coin_shares<MemeA>(version, &admin, bps::new(23), bps::new(45), &clock);
        clock.set_for_testing(172_800_000);
        f.policy.apply_coin_shares<MemeA>(version, &clock);
        f.policy.schedule_clear_coin_shares<MemeA>(version, &admin, &clock);
        clock.set_for_testing(345_600_000);
        f.policy.apply_coin_shares<MemeA>(version, &clock);

        f.policy.schedule_clear_coin_shares<MemeA>(version, &admin, &clock);

        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_map)]
fun clearing_an_absent_coin_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.clear_coin_shares_for_testing<MemeA>(&f.migrators_version, &admin, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_destination_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.migrators_version.set_for_testing(2);
        f.policy.set_protocol_destination_for_testing(&f.migrators_version, &admin, PUBLISHER, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_default_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.migrators_version.set_for_testing(2);
        f
            .policy
            .set_default_shares_for_testing(
                &f.migrators_version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_coin_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                &f.migrators_version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
        f.migrators_version.set_for_testing(2);
        f
            .policy
            .set_coin_shares_for_testing<MemeA>(
                &f.migrators_version,
                &admin,
                bps::new(0),
                bps::new(0),
                f.scenario.ctx()
            );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_missing_coin_clear() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.migrators_version.set_for_testing(2);
        f.policy.clear_coin_shares_for_testing<MemeA>(&f.migrators_version, &admin, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
fun a_coin_override_set_at_zero_notice_waits_the_raised_coin_notice() {
    let mut fixture = start_zero_notice_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);
        // At zero notice a schedule and its apply in one transaction act as a setter.
        f.schedule_coin<MemeA>(10, 20, &clock);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(10, 20);
        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), RAISED_NOTICE_MS, &clock);
        f.policy.apply_coin_shares_delay(&f.migrators_version, &clock);
        assert_eq!(f.policy.coin_shares_for_testing().delay_ms(), RAISED_NOTICE_MS);

        // The override set at zero notice keeps no notice of its own: its next change, like a
        // new coin's first pair, waits the raised notice.
        f.schedule_coin<MemeA>(30, 40, &clock);
        f.schedule_coin<MemeB>(50, 60, &clock);
        assert_eq!(f.coin_ready_at_ms<MemeA>(), START_MS + RAISED_NOTICE_MS);
        assert_eq!(f.coin_ready_at_ms<MemeB>(), START_MS + RAISED_NOTICE_MS);
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS);
        f.assert_shares<MemeA>(10, 20);
        f.assert_shares<MemeB>(0, 0);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.policy.apply_coin_shares<MemeB>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(30, 40);
        f.assert_shares<MemeB>(50, 60);
        destroy(clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_map)]
fun a_coin_override_set_at_zero_notice_cannot_change_before_the_raised_notice() {
    let mut fixture = start_zero_notice_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);
        f.schedule_coin<MemeA>(10, 20, &clock);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), RAISED_NOTICE_MS, &clock);
        f.policy.apply_coin_shares_delay(&f.migrators_version, &clock);

        f.schedule_coin<MemeA>(30, 40, &clock);
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS - 1);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        destroy(clock);
    });
    fixture.end();
}

#[test]
fun clearing_a_coin_override_is_a_delayed_change() {
    let mut fixture = start_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let version = &f.migrators_version;
        f.policy.set_coin_shares_for_testing<MemeA>(version, &fee_admin(), bps::new(1), bps::new(2), f.scenario.ctx());
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);

        f.policy.schedule_clear_coin_shares<MemeA>(&f.migrators_version, &fee_admin(), &clock);
        let meme = type_name::with_original_ids<MemeA>();
        let proposal = f.policy.coin_shares_for_testing().pending(&meme).destroy_some();
        assert!(proposal.value().is_none());
        assert_eq!(proposal.notice().delay_ms(), RAISED_NOTICE_MS);
        assert_eq!(proposal.notice().ready_at_ms(), START_MS + RAISED_NOTICE_MS);
        f.assert_shares<MemeA>(1, 2);

        // Cancelling a ready clear keeps the override.
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS);
        f.policy.cancel_coin_shares<MemeA>(&f.migrators_version, &blast_acl::witness_for_testing<CancelAdmin>());
        assert!(f.policy.coin_shares_for_testing().pending(&meme).is_none());
        f.assert_shares<MemeA>(1, 2);

        f.policy.schedule_clear_coin_shares<MemeA>(&f.migrators_version, &fee_admin(), &clock);
        clock.set_for_testing(START_MS + 2 * RAISED_NOTICE_MS);
        f.assert_shares<MemeA>(1, 2);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(0, 0);
        assert!(!f.has_override<MemeA>());
        assert_eq!(
            f.coin_changes(),
            vector[coin_change<MemeA>(option::some(pair(1, 2))), coin_change<MemeA>(option::none())],
        );
        destroy(clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_map)]
fun a_coin_clear_cannot_apply_before_the_coin_notice() {
    let mut fixture = start_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let version = &f.migrators_version;
        f.policy.set_coin_shares_for_testing<MemeA>(version, &fee_admin(), bps::new(1), bps::new(2), f.scenario.ctx());
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);
        f.policy.schedule_clear_coin_shares<MemeA>(&f.migrators_version, &fee_admin(), &clock);
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS - 1);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        destroy(clock);
    });
    fixture.end();
}

#[test]
fun the_coin_notice_is_independent_of_the_defaults_notice() {
    let mut fixture = start_zero_notice_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);

        // Raising the defaults' notice leaves the coin notice at zero.
        f
            .policy
            .schedule_default_shares(
                &f.migrators_version,
                &fee_admin(),
                bps::new(0),
                bps::new(0),
                RAISED_NOTICE_MS,
                &clock
            );
        f.policy.apply_default_shares(&f.migrators_version, &clock);
        assert_eq!(f.policy.coin_shares_for_testing().delay_ms(), 0);
        f.schedule_coin<MemeA>(10, 20, &clock);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(10, 20);

        // Raising the coin notice further leaves the defaults' notice where it is.
        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), 2 * RAISED_NOTICE_MS, &clock);
        f.policy.apply_coin_shares_delay(&f.migrators_version, &clock);
        f.schedule_coin<MemeA>(30, 40, &clock);
        f
            .policy
            .schedule_default_shares(
                &f.migrators_version,
                &fee_admin(),
                bps::new(5),
                bps::new(6),
                RAISED_NOTICE_MS,
                &clock
            );
        assert_eq!(f.coin_ready_at_ms<MemeA>(), START_MS + 2 * RAISED_NOTICE_MS);
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS);
        f.policy.apply_default_shares(&f.migrators_version, &clock);
        f.assert_default_shares(5, 6);
        f.assert_shares<MemeA>(10, 20);
        clock.set_for_testing(START_MS + 2 * RAISED_NOTICE_MS);
        f.policy.apply_coin_shares<MemeA>(&f.migrators_version, &clock);
        f.assert_shares<MemeA>(30, 40);
        destroy(clock);
    });
    fixture.end();
}

#[test]
fun a_coin_notice_change_waits_the_applied_notice_and_can_be_cancelled() {
    let mut fixture = start_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);
        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), 0, &clock);
        let notice = f.policy.coin_shares_for_testing().pending_delay().destroy_some();
        assert_eq!(notice.delay_ms(), 0);
        assert_eq!(notice.ready_at_ms(), START_MS + RAISED_NOTICE_MS);

        clock.set_for_testing(START_MS + RAISED_NOTICE_MS);
        f.policy.cancel_coin_shares_delay(&f.migrators_version, &blast_acl::witness_for_testing<CancelAdmin>());
        assert!(f.policy.coin_shares_for_testing().pending_delay().is_none());
        assert_eq!(f.policy.coin_shares_for_testing().delay_ms(), RAISED_NOTICE_MS);

        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), 0, &clock);
        clock.set_for_testing(START_MS + 2 * RAISED_NOTICE_MS);
        f.policy.apply_coin_shares_delay(&f.migrators_version, &clock);
        assert_eq!(f.policy.coin_shares_for_testing().delay_ms(), 0);
        destroy(clock);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_coin_notice_reduction_cannot_apply_before_the_applied_notice() {
    let mut fixture = start_policy();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut clock = sui::clock::create_for_testing(f.scenario.ctx());
        clock.set_for_testing(START_MS);
        f.policy.schedule_coin_shares_delay(&f.migrators_version, &fee_admin(), 0, &clock);
        clock.set_for_testing(START_MS + RAISED_NOTICE_MS - 1);
        f.policy.apply_coin_shares_delay(&f.migrators_version, &clock);
        destroy(clock);
    });
    fixture.end();
}

// === Test Helpers ===

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun policy_next_tx(
    $fixture: &mut PolicyFixture,
    $sender: address,
    $fn: |&mut PolicyFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    lp_fee_policy::init_for_testing(scenario.ctx());
    assert_eq!(event::num_events(), 3);
    let destination = event::events_by_type<DelayedCreated<ProtocolDestinationKey, address>>();
    let (_, _, value, delay_ms) = destination[0].delayed_created_fields();
    assert_eq!(value, @blast_lp_fee_destination);
    assert_eq!(delay_ms, PUBLICATION_POLICY_NOTICE_MS);
    let defaults = event::events_by_type<DelayedCreated<DefaultSharesKey, SharePair>>();
    let (_, _, value, delay_ms) = defaults[0].delayed_created_fields();
    assert_eq!(bcs::to_bytes(&value), bcs::to_bytes(&pair(1_500, 1_500)));
    assert_eq!(delay_ms, PUBLICATION_POLICY_NOTICE_MS);
    // The per-coin overrides start empty at the same publication notice.
    let coins = event::events_by_type<MapCreated<CoinSharesKey, TypeName, SharePair>>();
    let (_, _, delay_ms) = coins[0].map_created_fields();
    assert_eq!(delay_ms, PUBLICATION_POLICY_NOTICE_MS);

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<LpFeePolicy>();

    InitFixture { scenario, policy }
}

/// A fresh policy.
fun start_policy(): PolicyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_zero_fees_for_testing(scenario.ctx());

    PolicyFixture { scenario, migrators_version, policy }
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

/// Asserts the pair a collection for `Meme` pays Blast right now.
fun assert_shares<Meme>(self: &PolicyFixture, meme_bps: u64, quote_bps: u64) {
    let (live_meme_bps, live_quote_bps) = self.policy.shares<Meme>();

    assert_eq!(live_meme_bps.value(), meme_bps);
    assert_eq!(live_quote_bps.value(), quote_bps);
}

/// Asserts the pair every coin without its own pair pays Blast right now.
fun assert_default_shares(self: &PolicyFixture, meme_bps: u64, quote_bps: u64) {
    let (default_meme_bps, default_quote_bps) = self.policy.default_shares_for_testing();

    assert_eq!(default_meme_bps.value(), meme_bps);
    assert_eq!(default_quote_bps.value(), quote_bps);
}

fun pair(meme_bps: u64, quote_bps: u64): ExpectedPair {
    ExpectedPair { meme_bps, quote_bps }
}

/// Encodes each applied default-pair change as its previous then new pair, checking its owner.
fun default_changes(self: &PolicyFixture): vector<vector<u8>> {
    let owner = object::id(&self.policy);

    event::events_by_type<DelayedApplied<DefaultSharesKey, SharePair>>().map!(|applied| {
        let (applied_owner, _, previous_value, value, _) = applied.delayed_applied_fields();
        assert_eq!(applied_owner, owner);
        let mut bytes = bcs::to_bytes(&previous_value);
        bytes.append(bcs::to_bytes(&value));
        bytes
    })
}

/// Encodes each applied coin-pair change as its coin key then new override (none when cleared),
/// checking its owner; coin-notice changes are skipped.
fun coin_changes(self: &PolicyFixture): vector<vector<u8>> {
    let owner = object::id(&self.policy);
    let mut changes = vector[];

    event::events_by_type<MapApplied<CoinSharesKey, TypeName, SharePair>>().do!(|applied| {
        let (applied_owner, _, change, _) = applied.map_applied_fields();
        assert_eq!(applied_owner, owner);
        change.entry_for_testing().do!(|entry| {
            let mut bytes = bcs::to_bytes(&entry);
            bytes.append(bcs::to_bytes(&change.entry_value_for_testing()));
            changes.push_back(bytes);
        });
    });

    changes
}

fun default_change(previous: ExpectedPair, value: ExpectedPair): vector<u8> {
    let mut bytes = bcs::to_bytes(&previous);
    bytes.append(bcs::to_bytes(&value));
    bytes
}

fun coin_change<Meme>(value: Option<ExpectedPair>): vector<u8> {
    let mut bytes = bcs::to_bytes(&type_name::with_original_ids<Meme>());
    bytes.append(bcs::to_bytes(&value));
    bytes
}

/// Whether `Meme` holds its own applied pair.
fun has_override<Meme>(self: &PolicyFixture): bool {
    self.policy.coin_shares_for_testing().value(&type_name::with_original_ids<Meme>()).is_some()
}

/// Proposes `Meme`'s own pair under the coin overrides' notice.
fun schedule_coin<Meme>(self: &mut PolicyFixture, meme_bps: u64, quote_bps: u64, clock: &Clock) {
    self
        .policy
        .schedule_coin_shares<Meme>(
            &self.migrators_version,
            &fee_admin(),
            bps::new(meme_bps),
            bps::new(quote_bps),
            clock
        );
}

/// When `Meme`'s pending change becomes ready.
fun coin_ready_at_ms<Meme>(self: &PolicyFixture): u64 {
    self
        .policy
        .coin_shares_for_testing()
        .pending(&type_name::with_original_ids<Meme>())
        .destroy_some()
        .notice()
        .ready_at_ms()
}

/// A shared policy as publication leaves it, with zero notices and zero shares.
fun start_zero_notice_policy(): PolicyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    lp_fee_policy::init_zero_fees_for_testing(scenario.ctx());
    scenario.next_tx(PROTOCOL_ADMIN);
    let policy = scenario.take_shared<LpFeePolicy>();

    PolicyFixture { scenario, migrators_version, policy }
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun policy_end(self: PolicyFixture) {
    destroy(self);
}

// === Constants ===

const PUBLISHER: address = @0xA11CE;

/// The notice every policy change waits from publication.
const PUBLICATION_POLICY_NOTICE_MS: u64 = 172_800_000;

const PROTOCOL_ADMIN: address = @0xAD;

/// A nonzero start, so absolute timestamps cannot satisfy a notice by accident.
const START_MS: u64 = 1_234;

/// The 48-hour notice an administrator raises a zero notice to.
const RAISED_NOTICE_MS: u64 = 172_800_000;

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    delayed::{DelayedApplied, DelayedCreated},
    delayed_map::{MapApplied, MapCreated},
};

use blast_fun::{blast_fun_domain::{CancelAdmin, FeeAdmin, TreasuryAdmin}, bps};

use blast_fun_migrators::{
    lp_fee_policy::{
        Self,
        CoinSharesKey,
        DefaultSharesKey,
        LpFeePolicy,
        ProtocolDestinationKey,
        SharePair,
    },
    blast_fun_migrators::{Self as migrators_version, PackageVersion as MigratorsVersion},
};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{clock::Clock, event, test_scenario::{Self, Scenario}};

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun policy_end as PolicyFixture.end;

use fun policy_next_tx as PolicyFixture.next_tx;
