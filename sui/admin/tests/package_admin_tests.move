// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The generic publication, version, pause and upgrade-custody lifecycle every upgradeable
/// package shares, exercised with the `0xa` test marker.
module blast_admin::package_admin_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const OTHER_SENDER: address = @0xAD;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// The test marker's original package address.
const PACKAGE_ID: address = @0xa;

/// Create 1, trade 2 and migrate 4, as both sale products define them.
const VALID_PAUSE_BITS: u8 = 7;

const NOTICE_MS: u64 = 48 * 60 * 60 * 1_000;

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

    destroy(fixture);
}

#[test]
fun the_publication_holds_the_marker_packages_publisher() {
    let fixture = start_published();

    let publication = fixture.take_publication();
    assert!(publication.publisher_for_testing().from_package<PACKAGE_MARKER>());

    destroy(publication);
    destroy(fixture);
}

#[test]
fun wrapping_shares_custody_and_a_fully_paused_version_and_consumes_the_publication() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());

    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());
    let created = blast_admin_events::collect_one<
        blast_admin_events::UpgradeCustodyCreated<PACKAGE_MARKER>,
    >(0);

    fixture.scenario.next_tx(PUBLISHER);
    let package_admin = fixture.scenario.take_shared<PackageAdmin<PACKAGE_MARKER>>();
    let package_version = fixture.scenario.take_shared<PackageVersion<PACKAGE_MARKER>>();
    let custody = package_admin.custody_for_testing();
    let (
        emitted_custodian_id,
        emitted_publisher_id,
        emitted_upgrade_cap_id,
        emitted_package_id,
        emitted_native_version,
        emitted_policy,
    ) = created.upgrade_custody_created_fields();

    assert!(!fixture.scenario.has_most_recent_for_sender<Publication<PACKAGE_MARKER>>());
    assert_eq!(emitted_custodian_id, object::id(&package_admin));
    assert_eq!(emitted_publisher_id, custody.publisher_id_for_testing());
    assert_eq!(emitted_upgrade_cap_id, custody.upgrade_cap_id_for_testing());
    assert_eq!(emitted_package_id, PACKAGE_ID.to_id());
    assert_eq!(emitted_native_version, 1);
    assert_eq!(emitted_policy, package::compatible_policy());
    assert!(custody.has_upgrade_cap());
    assert_eq!(package_admin.upgrade_for_testing().delay_ms(), NOTICE_MS);
    assert_eq!(package_version.paused_for_testing(), VALID_PAUSE_BITS);
    assert_eq!(package_version.valid_pause_bits_for_testing(), VALID_PAUSE_BITS);
    assert_eq!(package_version.generation_for_testing(), 1);
    package_version.assert_current(1);

    test_scenario::return_shared(package_admin);
    test_scenario::return_shared(package_version);
    destroy(fixture);
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

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun another_sender_cannot_take_the_publication() {
    let mut fixture = start_published();

    fixture.scenario.next_tx(OTHER_SENDER);
    destroy(fixture.take_publication());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackageMarker,
    location = blast_admin::operational_version,
)]
fun a_publication_requires_the_packages_one_time_witness() {
    let mut ctx = tx_context::dummy();

    let publication = package_version::new_publication(
        package_marker::witness(),
        VALID_PAUSE_BITS,
        &mut ctx,
    );

    destroy(publication);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::upgrade_custody)]
fun wrap_rejects_an_upgrade_cap_for_another_package() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let foreign_upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), fixture.scenario.ctx());

    package_admin::wrap(publication, foreign_upgrade_cap, fixture.scenario.ctx());

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::upgrade_custody)]
fun wrap_rejects_an_already_upgraded_cap() {
    let mut fixture = start_published();
    let publication = fixture.take_publication();
    let mut upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.scenario.ctx());
    let ticket = upgrade_cap.authorize_upgrade(package::compatible_policy(), package_digest());
    upgrade_cap.commit(ticket.test_upgrade());

    package_admin::wrap(publication, upgrade_cap, fixture.scenario.ctx());

    destroy(fixture);
}

#[test]
fun a_compatible_upgrade_commits_and_advances_one_generation_together() {
    let mut owned = start();
    let fixture = &mut owned;

    let ticket = fixture.authorize(package_digest());
    assert_eq!(ticket.ticket_policy(), package::compatible_policy());
    let authorized = blast_admin_events::collect_one<
        blast_admin_events::UpgradeAuthorized<PACKAGE_MARKER>,
    >(0);
    fixture
        .package_admin
        .commit_upgrade_and_advance(&mut fixture.package_version, &upgrade_admin(), ticket.test_upgrade());
    let advanced = blast_admin_events::collect_one<
        blast_admin_events::OperationalVersionAdvanced<PACKAGE_MARKER>,
    >(0);

    let (_, _, _, _, _, authorized_digest) = authorized.upgrade_authorized_fields();
    let (container_id, original_package_id, previous_generation, new_generation) = advanced
        .operational_version_advanced_fields();
    assert_eq!(authorized_digest, package_digest());
    assert_eq!(container_id, object::id(&fixture.package_version));
    assert_eq!(original_package_id, PACKAGE_ID);
    assert_eq!(previous_generation, 1);
    assert_eq!(new_generation, 2);
    assert_eq!(fixture.package_admin.custody_for_testing().native_version_for_testing(), 2);
    assert_eq!(fixture.package_version.generation_for_testing(), 2);
    fixture.package_version.assert_current(2);
    fixture.package_version.assert_next(3);

    owned.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_committed_upgrade_disables_the_old_bytecode() {
    let mut owned = start();
    let fixture = &mut owned;
    let ticket = fixture.authorize(package_digest());
    fixture
        .package_admin
        .commit_upgrade_and_advance(&mut fixture.package_version, &upgrade_admin(), ticket.test_upgrade());

    fixture.package_version.assert_current(1);

    owned.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun assert_next_rejects_a_skipped_generation() {
    let owned = start();
    let fixture = &owned;

    fixture.package_version.assert_next(3);

    owned.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionOverflow,
    location = blast_admin::operational_version,
)]
fun commit_rejects_generation_overflow() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_version.set_generation_for_testing(std::u64::max_value!());
    let ticket = fixture.authorize(package_digest());

    fixture
        .package_admin
        .commit_upgrade_and_advance(&mut fixture.package_version, &upgrade_admin(), ticket.test_upgrade());

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
        .commit_upgrade_and_advance(&mut fixture.package_version, &upgrade_admin(), receipt);

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
fun an_upgrade_waits_the_48_hour_publication_notice() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS - 1);

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
    fixture.clock.set_for_testing(NOTICE_MS);

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
    fixture.clock.set_for_testing(NOTICE_MS);

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
    fixture.clock.set_for_testing(NOTICE_MS);

    fixture.package_admin.make_immutable(&upgrade_admin(), &fixture.clock);

    owned.end();
}

#[test]
fun package_admin_can_permanently_destroy_native_upgrade_authority() {
    let mut owned = start();
    let fixture = &mut owned;
    let upgrade_cap_id = fixture.package_admin.custody_for_testing().upgrade_cap_id_for_testing();

    fixture.package_admin.make_immutable_for_testing(&upgrade_admin(), &mut fixture.ctx);
    let destroyed = blast_admin_events::collect_one<
        blast_admin_events::UpgradeCapDestroyed<PACKAGE_MARKER>,
    >(0);

    let (custodian_id, destroyed_cap_id, original_package_id, _, _) = destroyed
        .upgrade_cap_destroyed_fields();
    assert_eq!(custodian_id, fixture.package_admin.id_for_testing());
    assert_eq!(destroyed_cap_id, upgrade_cap_id);
    assert_eq!(original_package_id, PACKAGE_ID);
    assert!(!fixture.package_admin.custody_for_testing().has_upgrade_cap());

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun authorization_is_rejected_after_immutability() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(&upgrade_admin(), &mut fixture.ctx);

    let ticket = fixture.authorize(package_digest());

    destroy(ticket);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun repeated_immutability_is_rejected() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.make_immutable_for_testing(&upgrade_admin(), &mut fixture.ctx);

    fixture.package_admin.make_immutable_for_testing(&upgrade_admin(), &mut fixture.ctx);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENoPending, location = blast_admin::delayed_action)]
fun a_cancelled_upgrade_cannot_be_authorized() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.package_admin.cancel_upgrade_action(&cancel_admin());
    fixture.clock.set_for_testing(NOTICE_MS);

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
fun a_notice_change_waits_the_applied_notice_and_cancellation_keeps_it() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.package_admin.cancel_upgrade_action(&cancel_admin());
    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), NOTICE_MS);

    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 25, &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS);
    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), 25);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::ENotReady, location = blast_admin::delayed)]
fun a_notice_reduction_cannot_be_applied_early() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS - 1);

    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_ready_immutability_action_cannot_be_applied_as_a_notice_change() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_make_immutable(&upgrade_admin(), &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS);

    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    owned.end();
}

#[test]
fun an_upgrade_action_replaces_a_pending_notice_change() {
    let mut owned = start();
    let fixture = &mut owned;
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 25, &fixture.clock);
    fixture.package_admin.schedule_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS);

    let ticket = fixture
        .package_admin
        .authorize_upgrade(&upgrade_admin(), package_digest(), &fixture.clock);

    assert_eq!(fixture.package_admin.upgrade_for_testing().delay_ms(), NOTICE_MS);
    destroy(ticket);
    owned.end();
}

#[test]
fun pausing_sets_only_the_requested_bits_and_gates_those_operations() {
    let mut owned = start();
    let fixture = &mut owned;

    package_admin::pause(&mut fixture.package_version, &pause_admin(), 2);
    let paused = blast_admin_events::collect_one<blast_admin_events::Paused<PACKAGE_MARKER>>(0);

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
    let mut package_version = package_version::new_for_testing<PACKAGE_MARKER>(0, &mut ctx);

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

    fixture.clear(package_marker::witness(), 2);
    let unpaused = blast_admin_events::collect_one<blast_admin_events::Unpaused<PACKAGE_MARKER>>(0);

    let (package_version_id, bits, mask) = unpaused.unpaused_fields();
    assert_eq!(package_version_id, object::id(&fixture.package_version));
    assert_eq!(bits, 2);
    assert_eq!(mask, 5);
    fixture.package_version.assert_not_paused(2);
    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_admin)]
fun clearing_rejects_a_witness_from_another_package() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(foreign_package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_admin)]
fun clearing_rejects_a_primitive_witness() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(7u8, 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageWitness, location = blast_admin::package_admin)]
fun the_witness_is_checked_before_the_upgrade_notice() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);

    fixture.clear(foreign_package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedUpgradeNotice, location = blast_admin::package_admin)]
fun clearing_rejects_a_pending_zero_upgrade_notice() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);

    fixture.clear(package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedUpgradeNotice, location = blast_admin::package_admin)]
fun clearing_rejects_an_applied_zero_upgrade_notice() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);
    fixture.package_admin.schedule_upgrade_delay(&upgrade_admin(), 0, &fixture.clock);
    fixture.clock.set_for_testing(NOTICE_MS);
    fixture.package_admin.apply_upgrade_delay(&fixture.clock);

    fixture.clear(package_marker::witness(), 1);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EPauseUnchanged, location = blast_admin::package_version)]
fun clearing_rejects_bits_that_are_not_set() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(package_marker::witness(), 2);

    owned.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_admin::package_version)]
fun clearing_rejects_a_bit_the_package_does_not_define() {
    let mut owned = start();
    let fixture = &mut owned;
    package_admin::pause(&mut fixture.package_version, &pause_admin(), 1);

    fixture.clear(package_marker::witness(), 9);

    owned.end();
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

    let roles = acl.admin_roles_for_testing(admin_cap_id);
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

/// Runs the marker's publication as its initializer would.
fun start_published(): WrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    package_version::new_publication(package_marker::marker(), VALID_PAUSE_BITS, scenario.ctx())
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
        package::test_claim(package_marker::marker(), &mut ctx),
        package::test_publish(PACKAGE_ID.to_id(), &mut ctx),
        &mut ctx,
    );
    let package_version = package_version::new_for_testing(VALID_PAUSE_BITS, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);

    AdminFixture { package_admin, package_version, clock, ctx }
}

fun authorize(self: &mut AdminFixture, digest: vector<u8>): UpgradeTicket {
    self.package_admin.authorize_upgrade_for_testing(&upgrade_admin(), digest, &mut self.ctx)
}

fun clear<PackageWitness: drop>(self: &mut AdminFixture, witness: PackageWitness, bits: u8) {
    self
        .package_admin
        .clear_pause_bits(&mut self.package_version, &unpause_admin(), witness, bits);
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

use 0xa::{other_package_marker::OTHER_PACKAGE_MARKER, package_marker::{Self, PACKAGE_MARKER}};

use 0xf::foreign_package_marker;

use blast_admin::{
    blast_acl::{Self, AdminCap, AdminWitness},
    blast_admin_events,
    errors,
    package_admin::{Self, CancelAdmin, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::{Self, PackageVersion, Publication}
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    package::{Self, UpgradeTicket},
    test_scenario::{Self, Scenario}
};
