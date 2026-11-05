// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_admin::errors` centralizes the immutable package's shared abort codes through
// zero-cost macros. W04005 observes expanded literals, so suppress it at the raising module.
#[allow(lint(abort_without_constant))]
/// The one access-control list for every Blast package: one cold root and role-typed admins.
///
/// A role is a type that its consumer package declares. `AdminWitness<Role>` in a function
/// signature is that function's role check, and a role from one package can never satisfy
/// another package's signature.
module blast_admin::blast_acl;

// === Constants ===

const MAX_ROLES_PER_ADMIN: u64 = 32;

/// The wait before a nominated super admin may accept the root.
const SUPER_ADMIN_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Public Types ===

/// The shared singleton that lists the active root and every live administrator's roles. It has
/// no destructor: every consumer's sign-in reads it for the life of the protocol.
public struct ACL has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: Table<ID, VecSet<TypeName>>,
    /// The nominated next super admin, acceptable once the fixed transfer delay passes.
    super_admin_transfer: DelayedAction<SuperAdminTransfer, address>,
}

/// Cold root authority for membership, roles, and delayed root replacement only.
public struct SuperAdminCap has key {
    id: UID,
}

/// Transferable, live-registry-checked administrator capability holding any granted roles.
public struct AdminCap has key, store {
    id: UID,
}

/// Keys the root transfer's delayed lifecycle events.
public struct SuperAdminTransfer() has copy, drop, store;

/// Transaction-local proof that a live `AdminCap` holding `Role` signed in.
public struct AdminWitness<phantom Role>() has drop;

// === Private Initialization ===

/// Delivers the root to `blast_acl_root` from `Move.toml`, not the publisher; an unset
/// (`0x0`) recipient aborts the publish rather than burn the root.
fun init(ctx: &mut TxContext) {
    assert!(@blast_acl_root != @0x0, blast_admin::errors::invalid_super_admin_recipient!());

    let (root, acl) = new(ctx);

    transfer::share_object(acl);
    transfer::transfer(root, @blast_acl_root);
}

// === Public Functions ===

/// Creates and delivers one live administrator that holds no role yet.
public fun grant_admin(
    self: &mut ACL,
    root: &SuperAdminCap,
    recipient: address,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(root);
    assert!(recipient != @0x0, blast_admin::errors::invalid_admin_recipient!());

    let admin_cap = AdminCap { id: object::new(ctx) };
    let admin_cap_id = admin_cap.id.to_inner();

    self.admins.add(admin_cap_id, vec_set::empty());
    transfer::public_transfer(admin_cap, recipient);

    blast_admin_events::admin_granted(admin_cap_id, recipient);
}

/// Revokes one live administrator and all its roles without requiring possession of its cap.
public fun revoke_admin(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = self.admins.remove(admin_cap_id);

    blast_admin_events::admin_revoked(admin_cap_id, roles.into_keys());
}

/// Adds `Role` to a live administrator.
public fun grant_role<Role>(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[admin_cap_id];
    let role = type_name::with_defining_ids<Role>();
    assert!(!roles.contains(&role), blast_admin::errors::admin_role_already_granted!());
    assert!(
        roles.length() < MAX_ROLES_PER_ADMIN,
        blast_admin::errors::admin_role_capacity_reached!(),
    );

    roles.insert(role);

    blast_admin_events::admin_role_granted(admin_cap_id, role);
}

/// Removes `Role` from a live administrator; an administrator with no role signs in to nothing.
public fun revoke_role<Role>(self: &mut ACL, root: &SuperAdminCap, admin_cap_id: ID) {
    self.assert_super_admin(root);
    assert!(self.admins.contains(admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    let roles = &mut self.admins[admin_cap_id];
    let role = type_name::with_defining_ids<Role>();
    assert!(roles.contains(&role), blast_admin::errors::admin_role_not_granted!());

    roles.remove(&role);

    blast_admin_events::admin_role_revoked(admin_cap_id, role);
}

/// Deletes an active or already-revoked administrator cap and reports what it still held.
public fun destroy_admin_cap(self: &mut ACL, admin_cap: AdminCap) {
    let AdminCap { id } = admin_cap;
    let admin_cap_id = id.to_inner();
    let was_active = self.admins.contains(admin_cap_id);
    let roles = if (was_active) {
        let roles = self.admins.remove(admin_cap_id);
        roles.into_keys()
    } else {
        vector[]
    };

    id.delete();

    blast_admin_events::admin_destroyed(admin_cap_id, roles, was_active);
}

/// Nominates `recipient` as the next super admin; it may accept once the transfer delay
/// passes. A new nomination cancels a pending one and restarts the delay.
public fun begin_super_admin_transfer(
    self: &mut ACL,
    root: &SuperAdminCap,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_super_admin(root);
    assert!(
        recipient != @0x0 && recipient != ctx.sender(),
        blast_admin::errors::invalid_super_admin_recipient!(),
    );

    self.super_admin_transfer.schedule(recipient, clock);
}

/// Cancels the pending root transfer at once, even after its delay has passed.
public fun cancel_super_admin_transfer(self: &mut ACL, root: &SuperAdminCap) {
    self.assert_super_admin(root);

    self.super_admin_transfer.cancel();
}

/// Accepts a ready root transfer as its nominated recipient and invalidates the old cap.
public fun accept_super_admin_transfer(self: &mut ACL, clock: &Clock, ctx: &mut TxContext) {
    let recipient = ctx.sender();
    assert!(
        self.super_admin_transfer.pending().is_some_and!(|proposal| {
            proposal.value().action() == option::some(recipient)
        }),
        blast_admin::errors::not_pending_super_admin_recipient!(),
    );

    self.super_admin_transfer.take_action(clock);

    let previous_super_admin_cap_id = self.super_admin_cap_id;
    let new_root = SuperAdminCap { id: object::new(ctx) };
    let new_super_admin_cap_id = new_root.id.to_inner();

    self.super_admin_cap_id = new_super_admin_cap_id;
    transfer::transfer(new_root, recipient);

    blast_admin_events::super_admin_transferred(
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    );
}

/// Deletes a root capability only after an accepted replacement made it inert.
public fun destroy_retired_super_admin_cap(self: &ACL, root: SuperAdminCap) {
    let super_admin_cap_id = root.id.to_inner();
    assert!(
        super_admin_cap_id != self.super_admin_cap_id,
        blast_admin::errors::super_admin_cap_still_active!(),
    );

    let SuperAdminCap { id } = root;
    id.delete();

    blast_admin_events::super_admin_cap_destroyed(super_admin_cap_id);
}

/// Proves that `admin_cap` is live and holds `Role`; the witness type is what consumers require.
public fun sign_in<Role>(self: &ACL, admin_cap: &AdminCap): AdminWitness<Role> {
    let admin_cap_id = admin_cap.id.to_inner();
    assert!(self.admins.contains(admin_cap_id), blast_admin::errors::invalid_admin_cap!());
    assert!(
        self.admins[admin_cap_id].contains(&type_name::with_defining_ids<Role>()),
        blast_admin::errors::admin_role_not_granted!(),
    );

    AdminWitness()
}

// Readers

/// The ID of the one root cap that works; any other `SuperAdminCap` is inert.
public fun super_admin_cap_id(self: &ACL): ID {
    self.super_admin_cap_id
}

/// Whether `admin_cap_id` names a live administrator.
public fun is_admin(self: &ACL, admin_cap_id: ID): bool {
    self.admins.contains(admin_cap_id)
}

/// Whether the live administrator `admin_cap_id` holds `Role`; false for an unknown cap.
public fun has_role<Role>(self: &ACL, admin_cap_id: ID): bool {
    self.admins.contains(admin_cap_id)
        && self.admins[admin_cap_id].contains(&type_name::with_defining_ids<Role>())
}

/// The role type names, with defining IDs, a live administrator holds.
public fun admin_roles(self: &ACL, admin_cap_id: ID): vector<TypeName> {
    assert!(self.admins.contains(admin_cap_id), blast_admin::errors::invalid_admin_cap!());

    self.admins[admin_cap_id].into_keys()
}

/// How many live administrators exist.
public fun admin_count(self: &ACL): u64 {
    self.admins.length()
}

/// The root transfer's delayed slot: its fixed notice and any pending nominee.
public fun super_admin_transfer(self: &ACL): &DelayedAction<SuperAdminTransfer, address> {
    &self.super_admin_transfer
}

/// The most roles one administrator can hold.
public fun max_roles_per_admin(): u64 {
    MAX_ROLES_PER_ADMIN
}

/// The fixed wait before a nominated super admin may accept the root, in milliseconds.
public fun super_admin_transfer_delay_ms(): u64 {
    SUPER_ADMIN_TRANSFER_DELAY_MS
}

// === Private Functions ===

fun new(ctx: &mut TxContext): (SuperAdminCap, ACL) {
    let root = SuperAdminCap { id: object::new(ctx) };
    let id = object::new(ctx);
    let super_admin_transfer = delayed_action::new(
        SuperAdminTransfer(),
        &id,
        SUPER_ADMIN_TRANSFER_DELAY_MS,
    );
    let acl = ACL {
        id,
        super_admin_cap_id: root.id.to_inner(),
        admins: table::new(ctx),
        super_admin_transfer,
    };

    (root, acl)
}

fun assert_super_admin(self: &ACL, root: &SuperAdminCap) {
    assert!(
        root.id.to_inner() == self.super_admin_cap_id,
        blast_admin::errors::invalid_super_admin_cap!(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): (SuperAdminCap, ACL) {
    new(ctx)
}

#[test_only]
/// Stands in for a live sign-in so consumer tests exercise only their own role signatures.
public fun witness_for_testing<Role>(): AdminWitness<Role> {
    AdminWitness()
}

#[test_only]
public fun super_admin_cap_id_for_testing(self: &SuperAdminCap): ID {
    self.id.to_inner()
}

#[test_only]
public fun admin_cap_id_for_testing(self: &AdminCap): ID {
    self.id.to_inner()
}

// === Imports ===

use blast_admin::blast_admin_events;

use blast_admin::delayed_action::{Self, DelayedAction};

use std::type_name::{Self, TypeName};

use sui::{clock::Clock, table::{Self, Table}, vec_set::{Self, VecSet}};
