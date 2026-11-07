// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Native UpgradeCap custody with an independent 48-hour notice per cap and action.
module blast_upgrade_cap_manager::blast_upgrade_cap_manager;

// === Public Types ===

/// Key-only custody for at most MAX_CAPS native caps, discoverable through the object table.
/// Each cap ID has at most one pending Request in a dynamic field on this manager.
public struct UpgradeCapManager has key {
    id: UID,
    caps: ObjectTable<ID, UpgradeCap>,
}

/// Transferable request, cancellation and enrollment authority for exactly one manager.
public struct ManagerCap has key, store {
    id: UID,
    manager_id: ID,
}

/// One cap's authorized action and inclusive execution timestamp, in Clock milliseconds.
public struct Request has copy, drop, store {
    action: Action,
    ready_at_ms: u64,
}

/// Mutually exclusive actions for one cap; other caps' requests remain independent.
public enum Action has copy, drop, store {
    Upgrade { digest: vector<u8> },
    MakeImmutable,
}

// === Public Functions ===

/// Creates a manager with its first native cap and an instance-bound controller.
/// Before valuable enrollment, independently verify destruction of this package's own cap.
public fun new(upgrade_cap: UpgradeCap, ctx: &mut TxContext): (UpgradeCapManager, ManagerCap) {
    assert!(upgrade_cap.package().to_address() != @0x0, EAlreadyAuthorized);
    let mut manager = UpgradeCapManager { id: object::new(ctx), caps: object_table::new(ctx) };
    let cap = ManagerCap { id: object::new(ctx), manager_id: manager.id.to_inner() };
    event::emit(ManagerCreated { manager_id: manager.id.to_inner(), controller_id: cap.id.to_inner() });
    manager.insert_cap(upgrade_cap);
    (manager, cap)
}

/// Shares a newly created manager; transfer its returned ManagerCap separately.
public fun share(self: UpgradeCapManager) {
    transfer::share_object(self);
}

/// Controller only: enrolls another native cap, up to MAX_CAPS active caps per manager.
/// The key is the original cap ID. No withdrawal path exists; native policy is preserved.
public fun add_upgrade_cap(self: &mut UpgradeCapManager, cap: &ManagerCap, upgrade_cap: UpgradeCap) {
    self.assert_controller(cap);
    assert!(upgrade_cap.package().to_address() != @0x0, EAlreadyAuthorized);
    assert!(self.caps.length() < MAX_CAPS, ECapacityReached);
    self.insert_cap(upgrade_cap);
}

/// Controller only: requests this cap's exact native digest after a full 48 hours.
/// Cancel this cap's existing request before replacement; other caps are unaffected.
public fun request_upgrade(
    self: &mut UpgradeCapManager,
    cap: &ManagerCap,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    clock: &Clock,
) {
    self.request(cap, upgrade_cap_id, Action::Upgrade { digest }, clock);
}

/// Controller only: requests permanent immutability of this cap's target after 48 hours.
public fun request_make_immutable(
    self: &mut UpgradeCapManager,
    cap: &ManagerCap,
    upgrade_cap_id: ID,
    clock: &Clock,
) {
    self.request(cap, upgrade_cap_id, Action::MakeImmutable, clock);
}

/// Controller only: cancels this cap's pending action, including after maturity.
public fun cancel_request(self: &mut UpgradeCapManager, cap: &ManagerCap, upgrade_cap_id: ID) {
    self.assert_controller(cap);
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);
    let Request { action, ready_at_ms } = dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);
    event::emit(RequestCancelled { manager_id: self.id.to_inner(), upgrade_cap_id, action, ready_at_ms });
}

/// Anyone: consumes this cap's mature request and authorizes its exact digest and native policy.
/// Consume the native ticket and commit its receipt in the same PTB; failures roll back atomically.
public fun authorize_upgrade(
    self: &mut UpgradeCapManager,
    upgrade_cap_id: ID,
    clock: &Clock,
): UpgradeTicket {
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);
    let request = dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id);
    let digest = match (&request.action) {
        Action::Upgrade { digest } => *digest,
        Action::MakeImmutable => abort EWrongAction,
    };
    let ready_at_ms = request.ready_at_ms;
    assert!(clock.timestamp_ms() >= ready_at_ms, ETooEarly);
    dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);
    let upgrade_cap = &mut self.caps[upgrade_cap_id];
    let policy = upgrade_cap.policy();
    let ticket = upgrade_cap.authorize(policy, digest);
    event::emit(UpgradeAuthorized { manager_id: self.id.to_inner(), upgrade_cap_id, digest, ready_at_ms });
    ticket
}

/// Anyone: commits to the cap identified by the native receipt; callers cannot redirect it.
public fun commit_upgrade(self: &mut UpgradeCapManager, receipt: UpgradeReceipt) {
    let upgrade_cap_id = receipt.cap();
    self.assert_managed(upgrade_cap_id);
    let upgrade_cap = &mut self.caps[upgrade_cap_id];
    upgrade_cap.commit(receipt);
    let package_id = upgrade_cap.package();
    let version = upgrade_cap.version();
    event::emit(UpgradeCommitted { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, version });
}

/// Anyone: executes this cap's mature immutability request and permanently destroys that cap.
/// Other caps, their requests and the shared manager survive. Application objects are not frozen.
public fun make_immutable(self: &mut UpgradeCapManager, upgrade_cap_id: ID, clock: &Clock) {
    self.assert_managed(upgrade_cap_id);
    assert!(dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ENoRequest);
    let request = dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id);
    assert!(request.action == Action::MakeImmutable, EWrongAction);
    let ready_at_ms = request.ready_at_ms;
    assert!(clock.timestamp_ms() >= ready_at_ms, ETooEarly);
    dynamic_field::remove<ID, Request>(&mut self.id, upgrade_cap_id);
    let upgrade_cap = self.caps.remove(upgrade_cap_id);
    let package_id = upgrade_cap.package();
    package::make_immutable(upgrade_cap);
    event::emit(PackageMadeImmutable { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, ready_at_ms });
}

/// Holder only: permanently renounces enrollment, request and cancellation authority.
/// All pending actions remain executable; this does not cancel them or destroy native caps.
public fun destroy_cap(cap: ManagerCap) {
    let ManagerCap { id, manager_id: _ } = cap;
    id.delete();
}

/// This cap's pending action and deadline, or none when idle or no longer managed.
public fun pending_request(self: &UpgradeCapManager, upgrade_cap_id: ID): Option<Request> {
    if (dynamic_field::exists<ID>(&self.id, upgrade_cap_id)) {
        option::some(*dynamic_field::borrow<ID, Request>(&self.id, upgrade_cap_id))
    } else {
        option::none()
    }
}

/// The exact upgrade digest or terminal immutability action authorized by the request.
public fun action(self: &Request): &Action {
    &self.action
}

/// Inclusive Clock timestamp when the request becomes executable.
public fun ready_at_ms(self: &Request): u64 {
    self.ready_at_ms
}

// === Private Functions ===

fun assert_controller(self: &UpgradeCapManager, cap: &ManagerCap) {
    assert!(cap.manager_id == self.id.to_inner(), EWrongController);
}

fun assert_managed(self: &UpgradeCapManager, upgrade_cap_id: ID) {
    assert!(self.caps.contains(upgrade_cap_id), EUnknownCap);
}

fun insert_cap(self: &mut UpgradeCapManager, upgrade_cap: UpgradeCap) {
    let upgrade_cap_id = object::id(&upgrade_cap);
    let package_id = upgrade_cap.package();
    let policy = upgrade_cap.policy();
    self.caps.add(upgrade_cap_id, upgrade_cap);
    event::emit(UpgradeCapAdded { manager_id: self.id.to_inner(), upgrade_cap_id, package_id, policy });
}

fun request(self: &mut UpgradeCapManager, cap: &ManagerCap, upgrade_cap_id: ID, action: Action, clock: &Clock) {
    self.assert_controller(cap);
    self.assert_managed(upgrade_cap_id);
    assert!(!dynamic_field::exists<ID>(&self.id, upgrade_cap_id), ERequestPending);
    assert!(self.caps[upgrade_cap_id].package().to_address() != @0x0, EAlreadyAuthorized);
    match (&action) {
        Action::Upgrade { digest } => assert!(digest.length() == DIGEST_LENGTH, EInvalidDigest),
        Action::MakeImmutable => (),
    };
    let requested_at_ms = clock.timestamp_ms();
    assert!(requested_at_ms <= MAX_TIMESTAMP_MS, ETimestampOverflow);
    let ready_at_ms = requested_at_ms + DELAY_MS;
    dynamic_field::add(&mut self.id, upgrade_cap_id, Request { action, ready_at_ms });
    match (action) {
        Action::Upgrade { digest } => event::emit(UpgradeRequested {
            manager_id: self.id.to_inner(), upgrade_cap_id, digest, requested_at_ms, ready_at_ms,
        }),
        Action::MakeImmutable => event::emit(ImmutabilityRequested {
            manager_id: self.id.to_inner(), upgrade_cap_id, requested_at_ms, ready_at_ms,
        }),
    };
}

// === Test-Only Types ===

#[test_only]
public struct Fixture {
    ctx: TxContext,
    clock: Clock,
    timelock: UpgradeCapManager,
    cap: ManagerCap,
    upgrade_cap_id: ID,
}

// === Test-Only Functions ===

#[test_only]
#[test]
fun fresh_custody_and_exact_deadline() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(123);
    let child = &timelock.caps[upgrade_cap_id];
    assert!(child.package() == object::id_from_address(@0xa));
    assert!(child.version() == 1 && child.policy() == package::compatible_policy());
    assert!(timelock.pending_request(upgrade_cap_id).is_none());
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    let request = timelock.pending_request(upgrade_cap_id).destroy_some();
    assert!(request.action() == &Action::Upgrade { digest: digest_a() });
    assert!(request.ready_at_ms() == 123 + DELAY_MS);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    assert!(timelock.pending_request(upgrade_cap_id).is_none());
    let child = &timelock.caps[upgrade_cap_id];
    assert!(child.version() == 2 && child.package().to_address() != @0xa);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun late_execution_and_second_upgrade_each_require_a_request() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(1_000);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS + 999);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    assert!(timelock.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == 1_999 + DELAY_MS * 2);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    let child = &timelock.caps[upgrade_cap_id];
    assert!(child.version() == 3);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun cancellation_after_maturity_and_replacement_restart_delay() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.cancel_request(&cap, upgrade_cap_id);
    assert!(timelock.pending_request(upgrade_cap_id).is_none());
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    let request = timelock.pending_request(upgrade_cap_id).destroy_some();
    assert!(request.action() == &Action::Upgrade { digest: digest_b() } && request.ready_at_ms() == DELAY_MS * 2);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun preserves_existing_restrictive_native_policy() {
    let Fixture { ctx: mut _ctx, mut clock, timelock, cap, upgrade_cap_id: _ } = fixture(0);
    let mut target_cap = package::test_publish(object::id_from_address(@0xb), &mut _ctx);
    target_cap.only_additive_upgrades();
    std::unit_test::destroy(timelock);
    std::unit_test::destroy(cap);
    let upgrade_cap_id = object::id(&target_cap);
    let (mut timelock, cap) = new(target_cap, &mut _ctx);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    assert!(ticket.policy() == package::additive_policy() && ticket.digest() == digest_a());
    timelock.commit_upgrade(package::test_upgrade(ticket));
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun last_representable_deadline_is_allowed() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(MAX_TIMESTAMP_MS);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EAlreadyAuthorized,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun enrollment_rejects_an_already_issued_ticket() {
    let Fixture { ctx: mut _ctx, clock, timelock, cap, upgrade_cap_id } = fixture(0);
    let mut target_cap = package::test_publish(object::id_from_address(@0xb), &mut _ctx);
    let ticket = target_cap.authorize(package::compatible_policy(), digest_a());
    let (new_timelock, new_cap) = new(target_cap, &mut _ctx);
    std::unit_test::destroy(ticket);
    std::unit_test::destroy(new_timelock);
    std::unit_test::destroy(new_cap);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongController,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun wrong_controller_cannot_request() {
    let Fixture { ctx: mut _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let (other, wrong) = other_timelock(&mut _ctx);
    std::unit_test::destroy(other);
    timelock.request_upgrade(&wrong, upgrade_cap_id, digest_a(), &clock);
    std::unit_test::destroy(wrong);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongController,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun wrong_controller_cannot_cancel() {
    let Fixture { ctx: mut _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    let (other, wrong) = other_timelock(&mut _ctx);
    std::unit_test::destroy(other);
    timelock.cancel_request(&wrong, upgrade_cap_id);
    std::unit_test::destroy(wrong);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ERequestPending,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun replacement_without_cancel_is_rejected() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EInvalidDigest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun short_digest_is_rejected() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, vector::tabulate!(31, |_| 0u8), &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EInvalidDigest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun long_digest_is_rejected() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, vector::tabulate!(33, |_| 0u8), &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETimestampOverflow,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun full_delay_must_fit_timestamp_range() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(MAX_TIMESTAMP_MS + 1);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ENoRequest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun cannot_cancel_when_idle() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.cancel_request(&cap, upgrade_cap_id);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ENoRequest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun cannot_authorize_without_request() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ENoRequest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun cannot_execute_cancelled_request() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.cancel_request(&cap, upgrade_cap_id);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ENoRequest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun cannot_replay_completed_request() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETooEarly,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun one_millisecond_early_is_rejected() {
    let Fixture { ctx: _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(777);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS - 1);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETooEarly,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun same_transaction_request_cannot_authorize() {
    let Fixture { ctx: _ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(1_000_000_000);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EUnknownCap,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun receipt_for_another_cap_is_rejected() {
    let Fixture { ctx: mut _ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    let (mut other, other_cap) = other_timelock(&mut _ctx);
    other.commit_upgrade(package::test_upgrade(ticket));
    std::unit_test::destroy(other);
    std::unit_test::destroy(other_cap);
    destroy_fixture(Fixture { ctx: _ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun immutability_at_exact_deadline_preserves_manager() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(123);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    let request = timelock.pending_request(upgrade_cap_id).destroy_some();
    assert!(request.action() == &Action::MakeImmutable);
    assert!(request.ready_at_ms() == 123 + DELAY_MS);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test]
fun switching_actions_after_cancellation_restarts_full_delay() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS + 1);
    timelock.cancel_request(&cap, upgrade_cap_id);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    assert!(timelock.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == DELAY_MS * 2 + 1);
    timelock.cancel_request(&cap, upgrade_cap_id);
    clock.increment_for_testing(1);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    assert!(timelock.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == DELAY_MS * 2 + 2);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun destroying_controller_preserves_pending_action() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    destroy_cap(cap);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test]
fun immutability_at_last_representable_deadline_is_allowed() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(MAX_TIMESTAMP_MS);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ENoRequest,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun immutability_without_request_is_rejected() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongAction,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun upgrade_request_cannot_authorize_immutability_even_before_deadline() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongAction,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun immutability_request_cannot_authorize_upgrade_even_before_deadline() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETooEarly,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun immutability_one_millisecond_early_is_rejected() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    clock.increment_for_testing(DELAY_MS - 1);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETooEarly,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun same_transaction_immutability_is_rejected() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    timelock.make_immutable(upgrade_cap_id, &clock);
    std::unit_test::destroy(timelock);
    destroy_cap(cap);
    std::unit_test::destroy(clock);
    std::unit_test::destroy(ctx);
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ETimestampOverflow,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun immutability_delay_must_fit_timestamp_range() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(MAX_TIMESTAMP_MS + 1);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ERequestPending,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun upgrade_request_blocks_immutability_replacement() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ERequestPending,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun immutability_request_blocks_upgrade_before_digest_validation() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    timelock.request_upgrade(&cap, upgrade_cap_id, vector[], &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongController,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun wrong_controller_cannot_request_immutability() {
    let Fixture { mut ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let (other, wrong) = other_timelock(&mut ctx);
    timelock.request_make_immutable(&wrong, upgrade_cap_id, &clock);
    std::unit_test::destroy(other);
    destroy_cap(wrong);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EAlreadyAuthorized,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun outstanding_ticket_blocks_immutability_request() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    timelock.commit_upgrade(package::test_upgrade(ticket));
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EAlreadyAuthorized,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun outstanding_ticket_blocks_upgrade_request() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    timelock.commit_upgrade(package::test_upgrade(ticket));
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun different_caps_have_independent_actions_deadlines_and_cancellation() {
    let Fixture { mut ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(123);
    let second_id = enroll_target(&mut timelock, &cap, &mut ctx);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    clock.increment_for_testing(1_000);
    timelock.request_make_immutable(&cap, second_id, &clock);
    let second = timelock.pending_request(second_id);
    timelock.cancel_request(&cap, upgrade_cap_id);
    assert!(timelock.pending_request(second_id) == second);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_b(), &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(second_id, &clock);
    assert!(!timelock.caps.contains(second_id));
    assert!(timelock.pending_request(second_id).is_none());
    assert!(timelock.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == 1_123 + DELAY_MS);
    complete_upgrade(&mut timelock, upgrade_cap_id, &clock);
    assert!(timelock.caps.length() == 1);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun simultaneous_tickets_commit_in_reverse_order_to_their_native_caps() {
    let Fixture { mut ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let second_id = enroll_target(&mut timelock, &cap, &mut ctx);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.request_upgrade(&cap, second_id, digest_b(), &clock);
    clock.increment_for_testing(DELAY_MS);
    let first = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    let second = timelock.authorize_upgrade(second_id, &clock);
    timelock.commit_upgrade(package::test_upgrade(second));
    timelock.commit_upgrade(package::test_upgrade(first));
    assert!(timelock.caps[upgrade_cap_id].version() == 2 && timelock.caps[second_id].version() == 2);
    assert!(timelock.pending_request(upgrade_cap_id).is_none() && timelock.pending_request(second_id).is_none());
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun outstanding_ticket_does_not_block_other_caps_requests_or_burns() {
    let Fixture { mut ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let second_id = enroll_target(&mut timelock, &cap, &mut ctx);
    let third_id = enroll_target(&mut timelock, &cap, &mut ctx);
    timelock.request_upgrade(&cap, upgrade_cap_id, digest_a(), &clock);
    timelock.request_make_immutable(&cap, second_id, &clock);
    clock.increment_for_testing(DELAY_MS);
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, &clock);
    timelock.request_upgrade(&cap, third_id, digest_b(), &clock);
    timelock.make_immutable(second_id, &clock);
    timelock.commit_upgrade(package::test_upgrade(ticket));
    assert!(timelock.pending_request(third_id).destroy_some().ready_at_ms() == DELAY_MS * 2);
    assert!(timelock.caps.length() == 2 && timelock.caps[upgrade_cap_id].version() == 2);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun full_capacity_accepts_requests_and_burning_frees_an_enrollment_slot() {
    let Fixture { mut ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    fill_manager(&mut timelock, &cap, &mut ctx);
    assert!(timelock.caps.length() == MAX_CAPS);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    assert!(timelock.caps.length() == MAX_CAPS - 1);
    let replacement_id = enroll_target(&mut timelock, &cap, &mut ctx);
    timelock.request_upgrade(&cap, replacement_id, digest_a(), &clock);
    assert!(timelock.caps.length() == MAX_CAPS);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test]
fun empty_manager_can_enroll_again_after_its_last_target_becomes_immutable() {
    let Fixture { mut ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    assert!(timelock.caps.is_empty());
    let replacement_id = enroll_target(&mut timelock, &cap, &mut ctx);
    timelock.request_upgrade(&cap, replacement_id, digest_a(), &clock);
    clock.increment_for_testing(DELAY_MS);
    complete_upgrade(&mut timelock, replacement_id, &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::ECapacityReached,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun first_enrollment_above_capacity_is_rejected() {
    let Fixture { mut ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    fill_manager(&mut timelock, &cap, &mut ctx);
    enroll_target(&mut timelock, &cap, &mut ctx);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EWrongController,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun wrong_controller_cannot_enroll_even_an_already_authorized_cap() {
    let Fixture { mut ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let (other, wrong) = other_timelock(&mut ctx);
    let mut target = package::test_publish(object::id_from_address(@0xc), &mut ctx);
    let ticket = target.authorize(package::compatible_policy(), digest_a());
    timelock.add_upgrade_cap(&wrong, target);
    std::unit_test::destroy(ticket);
    std::unit_test::destroy(other);
    destroy_cap(wrong);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EAlreadyAuthorized,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun additional_enrollment_rejects_an_outstanding_native_ticket() {
    let Fixture { mut ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let mut target = package::test_publish(object::id_from_address(@0xc), &mut ctx);
    let ticket = target.authorize(package::compatible_policy(), digest_a());
    timelock.add_upgrade_cap(&cap, target);
    std::unit_test::destroy(ticket);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EUnknownCap,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun unknown_cap_cannot_request() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let unknown_id = object::id_from_address(@0xdead);
    timelock.request_upgrade(&cap, unknown_id, vector[], &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EUnknownCap,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun unknown_cap_cannot_cancel() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let unknown_id = object::id_from_address(@0xdead);
    timelock.cancel_request(&cap, unknown_id);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EUnknownCap,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun unknown_cap_cannot_authorize() {
    let Fixture { ctx, clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    let unknown_id = object::id_from_address(@0xdead);
    let ticket = timelock.authorize_upgrade(unknown_id, &clock);
    std::unit_test::destroy(ticket);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
#[test, expected_failure(
    abort_code = blast_upgrade_cap_manager::blast_upgrade_cap_manager::EUnknownCap,
    location = blast_upgrade_cap_manager::blast_upgrade_cap_manager,
)]
fun removed_cap_cannot_be_made_immutable_again() {
    let Fixture { ctx, mut clock, mut timelock, cap, upgrade_cap_id } = fixture(0);
    timelock.request_make_immutable(&cap, upgrade_cap_id, &clock);
    clock.increment_for_testing(DELAY_MS);
    timelock.make_immutable(upgrade_cap_id, &clock);
    timelock.make_immutable(upgrade_cap_id, &clock);
    destroy_fixture(Fixture { ctx, clock, timelock, cap, upgrade_cap_id });
}

#[test_only]
fun enroll_target(timelock: &mut UpgradeCapManager, cap: &ManagerCap, ctx: &mut TxContext): ID {
    let target = package::test_publish(object::id_from_address(@0xc), ctx);
    let target_id = object::id(&target);
    timelock.add_upgrade_cap(cap, target);
    target_id
}

#[test_only]
fun fill_manager(timelock: &mut UpgradeCapManager, cap: &ManagerCap, ctx: &mut TxContext) {
    while (timelock.caps.length() < MAX_CAPS) {
        enroll_target(timelock, cap, ctx);
    };
}

#[test_only]
fun fixture(now_ms: u64): Fixture {
    let mut ctx = tx_context::dummy();
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(now_ms);
    let target_cap = package::test_publish(object::id_from_address(@0xa), &mut ctx);
    let upgrade_cap_id = object::id(&target_cap);
    let (timelock, cap) = new(target_cap, &mut ctx);
    Fixture { ctx, clock, timelock, cap, upgrade_cap_id }
}

#[test_only]
fun other_timelock(ctx: &mut TxContext): (UpgradeCapManager, ManagerCap) {
    let target_cap = package::test_publish(object::id_from_address(@0xb), ctx);
    new(target_cap, ctx)
}

#[test_only]
fun complete_upgrade(timelock: &mut UpgradeCapManager, upgrade_cap_id: ID, clock: &Clock) {
    let ticket = timelock.authorize_upgrade(upgrade_cap_id, clock);
    timelock.commit_upgrade(package::test_upgrade(ticket));
}

#[test_only]
fun destroy_fixture(f: Fixture) {
    std::unit_test::destroy(f);
}

#[test_only]
fun digest_a(): vector<u8> { vector::tabulate!(32, |_| 1u8) }

#[test_only]
fun digest_b(): vector<u8> { vector::tabulate!(32, |_| 2u8) }

// === Events ===

public struct ManagerCreated has copy, drop {
    manager_id: ID,
    controller_id: ID,
}

public struct UpgradeCapAdded has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    policy: u8,
}

public struct UpgradeRequested has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    requested_at_ms: u64,
    ready_at_ms: u64,
}

public struct RequestCancelled has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    action: Action,
    ready_at_ms: u64,
}

public struct UpgradeAuthorized has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    digest: vector<u8>,
    ready_at_ms: u64,
}

public struct UpgradeCommitted has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    version: u64,
}

public struct ImmutabilityRequested has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    requested_at_ms: u64,
    ready_at_ms: u64,
}

public struct PackageMadeImmutable has copy, drop {
    manager_id: ID,
    upgrade_cap_id: ID,
    package_id: ID,
    ready_at_ms: u64,
}

// === Constants ===

/// Maximum simultaneously custodied native caps; burning a cap frees a slot.
const MAX_CAPS: u64 = 256;
const DELAY_MS: u64 = 172_800_000;
const MAX_TIMESTAMP_MS: u64 = 18_446_744_073_709_551_615 - DELAY_MS;
const DIGEST_LENGTH: u64 = 32;

// === Errors ===

#[error(code = 0)]
const EAlreadyAuthorized: vector<u8> = b"An outstanding native upgrade ticket prevents enrollment or requests";
#[error(code = 1)]
const EWrongController: vector<u8> = b"Controller belongs to a different manager";
#[error(code = 2)]
const ERequestPending: vector<u8> = b"Cancel the existing request before requesting another";
#[error(code = 3)]
const EInvalidDigest: vector<u8> = b"A native upgrade digest must contain 32 bytes";
#[error(code = 4)]
const ETimestampOverflow: vector<u8> = b"The complete 48-hour delay exceeds the timestamp range";
#[error(code = 5)]
const ENoRequest: vector<u8> = b"No action has been requested";
#[error(code = 6)]
const EWrongAction: vector<u8> = b"The pending request authorizes a different action";
#[error(code = 7)]
const ETooEarly: vector<u8> = b"The request's full 48-hour delay has not elapsed";
#[error(code = 8)]
const EUnknownCap: vector<u8> = b"This UpgradeCap is not held by this manager";
#[error(code = 9)]
const ECapacityReached: vector<u8> = b"This manager already holds the maximum number of UpgradeCaps";

// === Imports ===

use sui::{
    clock::Clock,
    dynamic_field,
    event,
    object_table::{Self, ObjectTable},
    package::{Self, UpgradeCap, UpgradeReceipt, UpgradeTicket},
};
