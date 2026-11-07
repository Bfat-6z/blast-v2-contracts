// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The generic publication, version, pause and PackageAdmin lifecycle every upgradeable
/// package shares, exercised with the `0xa` test one-time witness (OTW).
module blast_admin::package_admin_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const OTHER_SENDER: address = @0xAD;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// The test OTW's original package address.
const PACKAGE_ID: address = @0xa;

/// Create 1, trade 2 and migrate 4, as both sale products define them.
const VALID_PAUSE_BITS: u8 = 7;

const DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// The production publication and wrap flow, run through `test_scenario`.
public struct WrapFixture {
    scenario: Scenario,
}

/// Unshared administration and version around unit-test capabilities.
public struct AdminFixture {
    package_admin: PackageAdmin<PACKAGE_MARKER>,
    package_version: PackageVersion<PACKAGE_MARKER>,
    clock: Clock,
    ctx: TxContext,
}

// === Tests ===

#[test]
fun a_publication_cannot_supply_the_version_operations_require() {
    let fixture = start_published();

    assert!(!test_scenario::has_most_recent_shared<PackageVersion<PACKAGE_MARKER>>());
    assert!(fixture.scenario.has_most_recent_for_sender<Publication<PACKAGE_MARKER>>());

    fixture.end();
}

#[test]
fun the_publication_holds_the_otw_packages_publisher() {
    let fixture = start_published();

    let publication = fixture.take_publication();
    assert!(publication.publisher_for_testing().from_package<PACKAGE_MARKER>());

    destroy(publication);
    fixture.end();
}

#[test]
fun wrapping_shares_the_package_admin_and_a_fully_paused_version_and_consumes_the_publication() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());

    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());
    let created = blast_admin_events::collect_one<
        PackageAdminCreated<PACKAGE_MARKER>,
    >(0);

    fixture.scenario.next_tx(PUBLISHER);
    let package_admin = fixture.scenario.take_shared<PackageAdmin<PACKAGE_MARKER>>();
    let package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();
    let (
        emitted_package_admin_id,
        emitted_publisher_id,
        emitted_upgrade_cap_id,
        emitted_package_id,
        emitted_upgrade_cap_version,
        emitted_policy,
    ) = created.package_admin_created_fields();

    assert!(!fixture.scenario.has_most_recent_for_sender<Publication<PACKAGE_MARKER>>());
    assert_eq!(emitted_package_admin_id, object::id(&package_admin));
    assert_eq!(emitted_publisher_id, object::id(package_admin.publisher_for_testing()));
    assert_eq!(emitted_upgrade_cap_id, package_admin.upgrade_cap_id().destroy_some());
    assert_eq!(emitted_package_id, PACKAGE_ID.to_id());
    assert_eq!(emitted_upgrade_cap_version, 1);
    assert_eq!(emitted_policy, package::compatible_policy());
    assert!(package_admin.has_upgrade_cap());
    assert!(package_admin.publisher_for_testing().from_package<PACKAGE_MARKER>());
    assert_eq!(package_admin.upgrade_for_testing().delay_ms(), DELAY_MS);
    assert_eq!(package_version.paused_for_testing(), VALID_PAUSE_BITS);
    assert_eq!(package_version.valid_pause_bits_for_testing(), VALID_PAUSE_BITS);
    assert_eq!(package_version.version_for_testing(), 1);
    package_version.assert_current(1);

    test_scenario::return_shared(package_admin);
    test_scenario::return_shared(package_version);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun a_consumed_publication_cannot_be_taken_for_another_wrap() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    fixture.scenario.next_tx(PUBLISHER);
    destroy(fixture.take_publication());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun another_sender_cannot_take_the_publication() {
    let mut fixture = start_published();

    fixture.scenario.next_tx(OTHER_SENDER);
    destroy(fixture.take_publication());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::package::ENotOneTimeWitness, location = sui::package)]
fun a_publication_requires_the_packages_one_time_witness() {
    let mut ctx = tx_context::dummy();

    let publication = package_version::new_publication<PackageWitness, OTHER_PACKAGE_MARKER>(
        package_marker::package_witness(),
        VALID_PAUSE_BITS,
        &mut ctx,
    );

    destroy(publication);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_version)]
fun a_publication_rejects_an_unpause_witness_from_another_package() {
    let mut ctx = tx_context::dummy();

    let publication = package_version::new_publication<PACKAGE_MARKER, ForeignWitness>(
        package_marker::otw(),
        VALID_PAUSE_BITS,
        &mut ctx,
    );

    destroy(publication);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_version)]
fun a_publication_rejects_a_primitive_package_witness() {
    let mut ctx = tx_context::dummy();

    let publication = package_version::new_publication<PACKAGE_MARKER, u8>(
        package_marker::otw(),
        VALID_PAUSE_BITS,
        &mut ctx,
    );

    destroy(publication);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_version)]
fun a_publication_rejects_its_own_otw_as_the_package_witness() {
    let mut ctx = tx_context::dummy();

    let publication = package_version::new_publication<PACKAGE_MARKER, PACKAGE_MARKER>(
        package_marker::otw(),
        VALID_PAUSE_BITS,
        &mut ctx,
    );

    destroy(publication);
}

#[test]
fun a_package_that_defines_no_bits_wraps_unpaused() {
    let mut fixture = start_published_with(0);
    let publication = fixture.take_publication();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    fixture.scenario.next_tx(PUBLISHER);
    let package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();

    assert_eq!(package_version.paused_for_testing(), 0);
    assert_eq!(package_version.valid_pause_bits_for_testing(), 0);
    package_version.assert_not_paused(1);
    package_version.assert_not_paused(0xff);

    test_scenario::return_shared(package_version);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::package_admin)]
fun wrap_rejects_an_upgrade_cap_for_another_package() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let foreign_upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), fixture.scenario.ctx());

    package_admin::wrap(publication, foreign_upgrade_cap, fixture.scenario.ctx());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::package_admin)]
fun wrap_rejects_an_already_upgraded_cap() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let mut upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    let ticket = upgrade_cap.authorize_upgrade(package::compatible_policy(), package_digest());
    upgrade_cap.commit(ticket.test_upgrade());

    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::package_admin)]
/// A cap with an outstanding ticket reports no package, so it cannot enter a PackageAdmin.
fun wrap_rejects_a_cap_with_an_outstanding_authorization() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let mut upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    let ticket = upgrade_cap.authorize_upgrade(package::compatible_policy(), package_digest());

    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    destroy(ticket);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::package_admin)]
/// With a zero delay one transaction could authorize, then make the package immutable, then
/// try to commit; the commit reports the missing cap.
fun commit_is_rejected_after_immutability() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );
    let mut foreign_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), &mut fixture.ctx);
    let receipt = foreign_cap
        .authorize_upgrade(package::compatible_policy(), package_digest())
        .test_upgrade();

    fixture
        .package_admin
        .commit_upgrade_and_advance(&upgrade_admin(), &mut fixture.package_version, receipt);

    destroy(foreign_cap);
    owned.end();
}

#[test]
fun a_compatible_upgrade_commits_and_advances_one_version_together() {
    let mut owned = start();
    let fixture = &mut owned;

    let ticket = fixture.authorize(package_digest());
    assert_eq!(ticket.ticket_policy(), package::compatible_policy());
    let authorized = blast_admin_events::collect_one<
        UpgradeAuthorized<PACKAGE_MARKER>,
    >(0);
    fixture
        .package_admin
        .commit_upgrade_and_advance(&upgrade_admin(), &mut fixture.package_version, ticket.test_upgrade());
    let advanced = blast_admin_events::collect_one<
        VersionAdvanced<PACKAGE_MARKER>,
    >(0);

    let committed = blast_admin_events::collect_one<
        UpgradeCommitted<PACKAGE_MARKER>,
    >(0);

    let (
        authorized_package_admin_id,
        authorized_cap_id,
        authorized_package_id,
        authorized_upgrade_cap_version,
        authorized_policy,
        authorized_digest,
    ) = authorized.upgrade_authorized_fields();
    assert_eq!(authorized_package_admin_id, fixture.package_admin.id_for_testing());
    assert_eq!(authorized_cap_id, fixture.package_admin.upgrade_cap_id().destroy_some());
    assert_eq!(authorized_package_id, PACKAGE_ID.to_id());
    assert_eq!(authorized_upgrade_cap_version, 1);
    assert_eq!(authorized_policy, package::compatible_policy());
    assert_eq!(authorized_digest, package_digest());
    let (
        committed_package_admin_id,
        committed_cap_id,
        committed_original_package_id,
        committed_package_id,
        previous_upgrade_cap_version,
        new_upgrade_cap_version,
    ) = committed.upgrade_committed_fields();
    assert_eq!(committed_package_admin_id, fixture.package_admin.id_for_testing());
    assert_eq!(committed_cap_id, fixture.package_admin.upgrade_cap_id().destroy_some());
    assert_eq!(committed_original_package_id, PACKAGE_ID);
    assert_eq!(committed_package_id, fixture.package_admin.current_package_id().destroy_some());
    assert!(committed_package_id != PACKAGE_ID.to_id());
    assert_eq!(previous_upgrade_cap_version, 1);
    assert_eq!(new_upgrade_cap_version, 2);
    let (container_id, original_package_id, previous_version, new_version) = advanced
        .version_advanced_fields();
    assert_eq!(container_id, object::id(&fixture.package_version));
    assert_eq!(original_package_id, PACKAGE_ID);
    assert_eq!(previous_version, 1);
    assert_eq!(new_version, 2);
    assert_eq!(fixture.package_admin.upgrade_cap_version().destroy_some(), 2);
    assert_eq!(fixture.package_version.version_for_testing(), 2);
    fixture.package_version.assert_current(2);

    owned.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun a_committed_upgrade_disables_the_old_bytecode() {
    let mut owned = start();
    let fixture = &mut owned;
    let ticket = fixture.authorize(package_digest());
    fixture
        .package_admin
        .commit_upgrade_and_advance(&upgrade_admin(), &mut fixture.package_version, ticket.test_upgrade());

    fixture.package_version.assert_current(1);

    owned.end();
}

#[test]
#[expected_failure(arithmetic_error, location = blast_admin::package_version)]
/// Unreachable in practice; the whole commit aborts rather than wrap the version.
fun commit_aborts_at_the_end_of_the_version_range() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_version.set_version_for_testing(std::u64::max_value!());
    let ticket = fixture.authorize(package_digest());

    fixture
        .package_admin
        .commit_upgrade_and_advance(&upgrade_admin(), &mut fixture.package_version, ticket.test_upgrade());

    owned.end();
}

#[test]
#[expected_failure(abort_code = sui::package::EWrongUpgradeCap, location = sui::package)]
fun commit_rejects_a_receipt_for_another_cap() {
    let mut owned = start();
    let fixture = &mut owned;
    let mut foreign_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), &mut fixture.ctx);
    let receipt = foreign_cap
        .authorize_upgrade(package::compatible_policy(), package_digest())
        .test_upgrade();

    fixture
        .package_admin
        .commit_upgrade_and_advance(&upgrade_admin(), &mut fixture.package_version, receipt);

    destroy(foreign_cap);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageDigest, location = blast_admin::package_admin)]
fun scheduling_rejects_a_digest_that_is_not_32_bytes() {
    let mut owned = start();
    let fixture = &mut owned;

    fixture
        .package_admin
        .schedule_upgrade(
            &upgrade_admin(),
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
            &fixture.clock,
        );

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun an_upgrade_waits_the_48_hour_publication_delay() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS - 1);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_admin::package_admin)]
fun authorization_rejects_a_digest_other_than_the_scheduled_one() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), other_package_digest(), &fixture.clock);

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_admin::package_admin)]
fun authorization_rejects_a_ready_immutability_action() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_admin::package_admin)]
fun immutability_rejects_a_ready_upgrade_action() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    fixture
        .package_admin
        .make_immutable(
            &upgrade_admin(),
            package_marker::package_witness(),
            &fixture.package_version,
            &fixture.clock,
        );

    owned.end();
}

#[test]
fun package_admin_can_permanently_destroy_native_upgrade_authority() {
    let mut owned = start();
    let fixture = &mut owned;
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id().destroy_some();
    let publisher_id = object::id(fixture.package_admin.publisher_for_testing());

    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );
    let destroyed = blast_admin_events::collect_one<
        UpgradeCapDestroyed<PACKAGE_MARKER>,
    >(0);

    let (package_admin_id, destroyed_cap_id, original_package_id, final_upgrade_cap_version, final_policy) =
        destroyed.upgrade_cap_destroyed_fields();
    assert_eq!(package_admin_id, fixture.package_admin.id_for_testing());
    assert_eq!(destroyed_cap_id, upgrade_cap_id);
    assert_eq!(original_package_id, PACKAGE_ID);
    assert_eq!(final_upgrade_cap_version, 1);
    assert_eq!(final_policy, package::compatible_policy());
    assert!(!fixture.package_admin.has_upgrade_cap());
    assert_eq!(object::id(fixture.package_admin.publisher_for_testing()), publisher_id);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::package_admin)]
fun scheduling_an_upgrade_is_rejected_after_immutability() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );

    let ticket = fixture.authorize(package_digest());

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::package_admin)]
/// After immutability the missing cap is reported before a malformed digest.
fun immutability_is_reported_before_a_malformed_digest() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );

    fixture.package_admin.schedule_upgrade(&upgrade_admin(), vector[0u8], &fixture.clock);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::package_admin)]
fun scheduling_immutability_again_is_rejected() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );

    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_upgrade_cannot_be_authorized() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.package_admin.cancel_upgrade_action(&cancel_admin());
    fixture.clock.set_for_testing(DELAY_MS);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_action)]
fun cancelling_with_nothing_scheduled_aborts() {
    let mut owned = start();
    let fixture = &mut owned;

    fixture.package_admin.cancel_upgrade_action(&cancel_admin());

    owned.end();
}

#[test]
fun a_delay_change_waits_the_applied_delay_and_cancellation_keeps_it() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.package_admin.cancel_upgrade_action(&cancel_admin());
    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), DELAY_MS);

    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 25, &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);
    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), 25);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun a_delay_reduction_cannot_be_applied_early() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS - 1);

    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_ready_immutability_action_cannot_be_applied_as_a_delay_change() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    owned.end();
}

#[test]
fun an_upgrade_action_replaces_a_pending_delay_change() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 25, &fixture.clock);
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);

    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), DELAY_MS);
    destroy(ticket);
    owned.end();
}

#[test]
fun pausing_sets_only_the_requested_bits_and_gates_those_operations() {
    let mut owned = start();
    let fixture = &mut owned;

    package_admin::pause(&mut fixture.package_version, &pause_admin(), 2);
    let paused = blast_admin_events::collect_one<Paused<PACKAGE_MARKER>>(0);

    let (package_version_id, bits, mask) = paused.paused_fields();
    assert_eq!(package_version_id, object::id(&fixture.package_version));
    assert_eq!(bits, 2);
    assert_eq!(mask, 2);
    assert_eq!(fixture.package_version.paused_for_testing(), 2);
    fixture.package_version.assert_not_paused(1);
    fixture.package_version.assert_not_paused(4);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EPaused, location = blast_admin::package_version)]
fun a_paused_bit_rejects_its_operation() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 4);

    fixture.package_version.assert_not_paused(4);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_admin::package_version)]
fun pausing_rejects_zero_bits() {
    let mut owned = start();
    let fixture = &mut owned;

    package_admin::pause(&mut fixture.package_version, &pause_admin(), 0);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_admin::package_version)]
fun pausing_rejects_a_bit_the_package_does_not_define() {
    let mut owned = start();
    let fixture = &mut owned;

    package_admin::pause(&mut fixture.package_version, &pause_admin(), 8);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_admin::package_version)]
fun a_package_that_defines_no_bits_cannot_pause() {
    let mut ctx = tx_context::dummy();
    let mut package_version = package_version::new_for_testing<PACKAGE_MARKER, PackageWitness>(
        0,
        &mut ctx,
    );

    package_admin::pause(&mut package_version, &pause_admin(), 1);

    destroy(package_version);
}

#[test]
#[expected_failure(abort_code = errors::EPauseUnchanged, location = blast_admin::package_version)]
fun pausing_rejects_bits_that_are_already_set() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 3);

    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    owned.end();
}

#[test]
fun clearing_releases_only_the_requested_bits() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), VALID_PAUSE_BITS);

    fixture.clear(package_marker::package_witness(), 2);
    let unpaused = blast_admin_events::collect_one<Unpaused<PACKAGE_MARKER>>(0);

    let (package_version_id, bits, mask) = unpaused.unpaused_fields();
    assert_eq!(package_version_id, object::id(&fixture.package_version));
    assert_eq!(bits, 2);
    assert_eq!(mask, 5);
    fixture.package_version.assert_not_paused(2);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUnpauseWitness, location = blast_admin::package_version)]
fun clearing_rejects_a_witness_from_another_package() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(foreign_package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUnpauseWitness, location = blast_admin::package_version)]
fun clearing_rejects_a_primitive_witness() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(7u8, 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUnpauseWitness, location = blast_admin::package_version)]
/// Any droppable type the package hands out, such as a value type its public calls return, is
/// still not the pinned witness.
fun clearing_rejects_another_droppable_type_from_the_same_package() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(other_package_marker::otw(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUnpauseWitness, location = blast_admin::package_version)]
fun the_witness_is_checked_before_the_upgrade_delay() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);

    fixture.clear(foreign_package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedUpgradeDelay, location = blast_admin::package_admin)]
fun clearing_rejects_a_pending_zero_upgrade_delay() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);

    fixture.clear(package_marker::package_witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedUpgradeDelay, location = blast_admin::package_admin)]
fun clearing_rejects_an_applied_zero_upgrade_delay() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);
    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    fixture.clear(package_marker::package_witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedUpgradeDelay, location = blast_admin::package_admin)]
fun the_upgrade_delay_is_checked_before_the_bits() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);

    fixture.clear(package_marker::package_witness(), 0);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EPauseUnchanged, location = blast_admin::package_version)]
fun clearing_rejects_bits_that_are_not_set() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(package_marker::package_witness(), 2);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_admin::package_version)]
fun clearing_rejects_a_bit_the_package_does_not_define() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(package_marker::package_witness(), 9);

    owned.end();
}

#[test]
/// The package witness borrows the Publisher its one-time witness claimed, which can create a
/// Display for the package's own types.
fun the_package_witness_borrows_the_packages_publisher() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let claimed_publisher_id = object::id(publication.publisher_for_testing());
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    fixture.scenario.next_tx(PUBLISHER);
    let package_admin = fixture.scenario.take_shared<PackageAdmin<PACKAGE_MARKER>>();
    let package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();
    let publisher = package_admin.publisher(package_marker::package_witness(), &package_version);

    assert_eq!(object::id(publisher), claimed_publisher_id);
    assert!(publisher.from_package<PACKAGE_MARKER>());
    let receipt_display = display::new<Receipt>(publisher, fixture.scenario.ctx());

    destroy(receipt_display);
    test_scenario::return_shared(package_admin);
    test_scenario::return_shared(package_version);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_publisher_rejects_a_witness_from_another_package() {
    let owned = start();

    owned.package_admin.publisher(foreign_package_marker::witness(), &owned.package_version);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_publisher_rejects_another_droppable_type_from_the_same_package() {
    let owned = start();

    owned.package_admin.publisher(other_package_marker::otw(), &owned.package_version);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_publisher_rejects_a_primitive_witness() {
    let owned = start();

    owned.package_admin.publisher(7u8, &owned.package_version);

    owned.end();
}

#[test]
fun version_and_publication_readers_report_version_bits_and_package_witness() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let witness = type_name::with_defining_ids<PackageWitness>();
    assert_eq!(publication.valid_pause_bits(), VALID_PAUSE_BITS);
    assert_eq!(publication.package_witness(), witness);
    assert_eq!(publication.publisher_id(), object::id(publication.publisher_for_testing()));
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    fixture.scenario.next_tx(PUBLISHER);
    let mut package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();
    assert_eq!(package_version.version(), 1);
    assert_eq!(package_version.valid_pause_bits(), VALID_PAUSE_BITS);
    assert_eq!(package_version.paused(), VALID_PAUSE_BITS);
    assert_eq!(package_version.package_witness(), witness);
    assert!(package_version.is_paused(2));
    package_version.set_version_for_testing(3);
    assert_eq!(package_version.version(), 3);

    test_scenario::return_shared(package_version);
    fixture.end();
}

#[test]
fun administration_readers_follow_the_upgrade_lifecycle_to_immutability() {
    let mut owned = start();
    let fixture = &mut owned;
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id().destroy_some();

    assert_eq!(package_admin::initial_upgrade_delay_ms(), DELAY_MS);
    assert_eq!(fixture.package_admin.upgrade_delay_ms(), DELAY_MS);
    assert!(fixture.package_admin.is_upgrade_delay_guarded());
    assert!(fixture.package_admin.pending_upgrade().is_none());
    assert!(fixture.package_admin.has_upgrade_cap());
    assert_eq!(fixture.package_admin.current_package_id(), option::some(PACKAGE_ID.to_id()));
    assert_eq!(fixture.package_admin.upgrade_cap_version(), option::some(1));
    assert_eq!(fixture.package_admin.upgrade_policy(), option::some(package::compatible_policy()));
    assert_eq!(
        fixture.package_admin.publisher_id(),
        object::id(fixture.package_admin.publisher_for_testing()),
    );

    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    let action = fixture.package_admin.pending_upgrade().destroy_some().value().action().destroy_some();
    assert_eq!(action.upgrade_digest(), option::some(package_digest()));
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    let action = fixture.package_admin.pending_upgrade().destroy_some().value().action().destroy_some();
    assert!(action.upgrade_digest().is_none());
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    assert!(!fixture.package_admin.is_upgrade_delay_guarded());
    fixture.package_admin.cancel_upgrade_action(&cancel_admin());

    fixture.package_admin.make_immutable_for_testing(
        &upgrade_admin(),
        package_marker::package_witness(),
        &fixture.package_version,
        &mut fixture.ctx,
    );
    let destroyed = blast_admin_events::collect_one<
        UpgradeCapDestroyed<PACKAGE_MARKER>,
    >(0);
    let (_, destroyed_cap_id, _, _, _) = destroyed.upgrade_cap_destroyed_fields();
    assert_eq!(destroyed_cap_id, upgrade_cap_id);
    assert!(!fixture.package_admin.has_upgrade_cap());
    assert!(fixture.package_admin.upgrade_cap_id().is_none());
    assert!(fixture.package_admin.current_package_id().is_none());
    assert!(fixture.package_admin.upgrade_cap_version().is_none());
    assert!(fixture.package_admin.upgrade_policy().is_none());

    owned.end();
}

#[test]
/// The mutable borrow reaches the same sealed Publisher, for framework calls that need it.
fun the_package_witness_borrows_the_publisher_mutably() {
    let AdminFixture { mut package_admin, package_version, clock, ctx: _ } = start();
    let publisher_id = package_admin.publisher_id();

    let publisher = package_admin.publisher_mut(package_marker::package_witness(), &package_version);

    assert_eq!(object::id(publisher), publisher_id);
    assert!(publisher.from_package<PACKAGE_MARKER>());
    destroy(package_admin);
    destroy(package_version);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_mutable_publisher_rejects_a_witness_from_another_package() {
    let AdminFixture { mut package_admin, package_version, clock, ctx: _ } = start();

    package_admin.publisher_mut(foreign_package_marker::witness(), &package_version);

    destroy(package_admin);
    destroy(package_version);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_mutable_publisher_rejects_another_droppable_type_from_the_same_package() {
    let AdminFixture { mut package_admin, package_version, clock, ctx: _ } = start();

    package_admin.publisher_mut(other_package_marker::otw(), &package_version);

    destroy(package_admin);
    destroy(package_version);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun the_mutable_publisher_rejects_a_primitive_witness() {
    let AdminFixture { mut package_admin, package_version, clock, ctx: _ } = start();

    package_admin.publisher_mut(7u8, &package_version);

    destroy(package_admin);
    destroy(package_version);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
/// Only the package's own code, holding its witness, can end its upgrades; checked before the
/// action is consumed.
fun immutability_rejects_a_witness_from_another_package() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    fixture
        .package_admin
        .make_immutable(
            &upgrade_admin(),
            foreign_package_marker::witness(),
            &fixture.package_version,
            &fixture.clock,
        );

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
fun immutability_rejects_another_droppable_type_from_the_same_package() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    fixture.clock.set_for_testing(DELAY_MS);

    fixture
        .package_admin
        .make_immutable(&upgrade_admin(), other_package_marker::otw(), &fixture.package_version, &fixture.clock);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongPackageWitness, location = blast_admin::package_version)]
/// The witness is checked before the action, so a wrong witness wins over a missing schedule.
fun the_immutability_witness_is_checked_before_the_action() {
    let mut owned = start();
    let fixture = &mut owned;

    fixture.package_admin.make_immutable(&upgrade_admin(), 7u8, &fixture.package_version, &fixture.clock);

    owned.end();
}

#[test]
/// Wrap records the new version, beside its administration, in one replay-complete event.
fun wrap_emits_the_package_version_created_with_its_exact_payload() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());
    let created = blast_admin_events::collect_one<PackageVersionCreated<PACKAGE_MARKER>>(0);

    fixture.scenario.next_tx(PUBLISHER);
    let package_admin = fixture.scenario.take_shared<PackageAdmin<PACKAGE_MARKER>>();
    let package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();
    let (package_version_id, package_admin_id, valid_pause_bits, paused, package_witness, version) =
        created.package_version_created_fields();
    assert_eq!(package_version_id, object::id(&package_version));
    assert_eq!(package_admin_id, object::id(&package_admin));
    assert_eq!(valid_pause_bits, VALID_PAUSE_BITS);
    assert_eq!(paused, VALID_PAUSE_BITS);
    assert_eq!(package_witness, type_name::with_defining_ids<PackageWitness>());
    assert_eq!(version, 1);
    let mut expected = bcs::to_bytes(&package_version_id);
    expected.append(bcs::to_bytes(&package_admin_id));
    expected.append(bcs::to_bytes(&valid_pause_bits));
    expected.append(bcs::to_bytes(&paused));
    expected.append(bcs::to_bytes(&package_witness));
    expected.append(bcs::to_bytes(&version));
    assert_eq!(bcs::to_bytes(&created), expected);

    test_scenario::return_shared(package_admin);
    test_scenario::return_shared(package_version);
    fixture.end();
}

#[test]
fun the_acl_keeps_one_packages_role_apart_from_anothers() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (root, mut acl) = blast_acl::new_for_testing(scenario.ctx());
    acl.grant_admin(&root, OTHER_SENDER, scenario.ctx());
    scenario.next_tx(OTHER_SENDER);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    acl.grant_role<UpgradeAdmin<PACKAGE_MARKER>>(&root, admin_cap_id);
    acl.grant_role<UpgradeAdmin<OTHER_PACKAGE_MARKER>>(&root, admin_cap_id);
    acl.revoke_role<UpgradeAdmin<OTHER_PACKAGE_MARKER>>(&root, admin_cap_id);

    let roles = acl.admin_roles(admin_cap_id);
    assert_eq!(roles, vector[type_name::with_defining_ids<UpgradeAdmin<PACKAGE_MARKER>>()]);
    assert!(roles[0] != type_name::with_defining_ids<UpgradeAdmin<OTHER_PACKAGE_MARKER>>());
    let _: AdminWitness<UpgradeAdmin<PACKAGE_MARKER>> = acl.sign_in(&admin_cap);

    destroy(admin_cap);
    destroy(acl);
    destroy(root);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = errors::EAdminRoleNotGranted, location = blast_admin::blast_acl)]
fun one_packages_upgrade_role_cannot_sign_in_for_another_package() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (root, mut acl) = blast_acl::new_for_testing(scenario.ctx());
    acl.grant_admin(&root, OTHER_SENDER, scenario.ctx());
    scenario.next_tx(OTHER_SENDER);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    acl.grant_role<UpgradeAdmin<PACKAGE_MARKER>>(&root, admin_cap.admin_cap_id_for_testing());

    let _: AdminWitness<UpgradeAdmin<OTHER_PACKAGE_MARKER>> = acl.sign_in(&admin_cap);

    destroy(admin_cap);
    destroy(acl);
    destroy(root);
    scenario.end();
}

// === Test Helpers ===

/// Runs the OTW's publication as its initializer would.
fun start_published(): WrapFixture {
    start_published_with(VALID_PAUSE_BITS)
}

fun start_published_with(valid_pause_bits: u8): WrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    package_version::new_publication<PACKAGE_MARKER, PackageWitness>(
        package_marker::otw(),
        valid_pause_bits,
        scenario.ctx(),
    )
        .keep(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    WrapFixture { scenario }
}

fun take_publication(self: &WrapFixture): Publication<PACKAGE_MARKER> {
    self.scenario.take_from_sender()
}

fun start(): AdminFixture {
    let mut ctx = tx_context::dummy();
    let package_admin = package_admin::new_for_testing<PACKAGE_MARKER>(
        package::test_claim(package_marker::otw(), &mut ctx),
        package::test_publish(PACKAGE_ID.to_id(), &mut ctx),
        &mut ctx,
    );
    let package_version = package_version::new_for_testing<PACKAGE_MARKER, PackageWitness>(
        VALID_PAUSE_BITS,
        &mut ctx,
    );
    let clock = clock::create_for_testing(&mut ctx);

    AdminFixture { package_admin, package_version, clock, ctx }
}

fun authorize(self: &mut AdminFixture, digest: vector<u8>): UpgradeTicket {
    self.package_admin.authorize_upgrade_for_testing(&upgrade_admin(), digest, &mut self.ctx)
}

fun clear<Witness: drop>(self: &mut AdminFixture, witness: Witness, bits: u8) {
    self
        .package_admin
        .clear_pause_bits(&unpause_admin(), witness, &mut self.package_version, bits);
}

/// Ends the wrap flow's scenario, which runs its end-of-scenario checks.
fun wrap_fixture_end(self: WrapFixture) {
    let WrapFixture { scenario } = self;

    scenario.end();
}

fun end(self: AdminFixture) {
    let AdminFixture { package_admin, package_version, clock, ctx: _ } = self;

    destroy(package_admin);
    destroy(package_version);
    clock.destroy_for_testing();
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin<PACKAGE_MARKER>> {
    blast_acl::witness_for_testing()
}

fun pause_admin(): AdminWitness<PauseAdmin<PACKAGE_MARKER>> {
    blast_acl::witness_for_testing()
}

fun unpause_admin(): AdminWitness<UnpauseAdmin<PACKAGE_MARKER>> {
    blast_acl::witness_for_testing()
}

fun cancel_admin(): AdminWitness<CancelAdmin<PACKAGE_MARKER>> {
    blast_acl::witness_for_testing()
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun other_package_digest(): vector<u8> {
    x"ffeeddccbbaa00998877665544332211112233445566778899aabbccddeeff00"
}

// === Imports ===

use 0xa::{
    other_package_marker::{Self, OTHER_PACKAGE_MARKER},
    package_marker::{Self, PACKAGE_MARKER, PackageWitness, Receipt}
};

use 0xf::foreign_package_marker::{Self, ForeignWitness};

use blast_admin::{
    blast_acl::{Self, AdminCap, AdminWitness},
    blast_admin_events::{
        Self,
        VersionAdvanced,
        PackageVersionCreated,
        Paused,
        Unpaused,
        UpgradeAuthorized,
        UpgradeCapDestroyed,
        UpgradeCommitted,
        PackageAdminCreated,
    },
    errors,
    package_admin::{Self, CancelAdmin, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::{Self, PackageVersion, Publication}
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    display,
    package::{Self, UpgradeTicket},
    test_scenario::{Self, Scenario}
};

use fun wrap_fixture_end as WrapFixture.end;
