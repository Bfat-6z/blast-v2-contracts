// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Replay-complete typed facts for shared administration transitions.
module blast_admin::blast_admin_events;

// === Public Types ===

public struct AdminGranted has copy, drop {
    admin_cap_id: ID,
    recipient: address,
}

public struct AdminRevoked has copy, drop {
    admin_cap_id: ID,
    roles: vector<TypeName>,
}

public struct AdminRoleGranted has copy, drop {
    admin_cap_id: ID,
    role: TypeName,
}

public struct AdminRoleRevoked has copy, drop {
    admin_cap_id: ID,
    role: TypeName,
}

public struct AdminDestroyed has copy, drop {
    admin_cap_id: ID,
    roles: vector<TypeName>,
    was_active: bool,
}

public struct SuperAdminTransferred has copy, drop {
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
}

public struct SuperAdminCapDestroyed has copy, drop {
    super_admin_cap_id: ID,
}

/// A package version moved to its next version; `container_id` is that `PackageVersion`.
public struct VersionAdvanced<phantom OTW: drop> has copy, drop {
    container_id: ID,
    original_package_id: address,
    previous_version: u64,
    new_version: u64,
}

/// A package version was created at wrap, beside the administration `package_admin_id`, with its
/// defined and paused bits, pinned package witness and first version.
public struct PackageVersionCreated<phantom OTW: drop> has copy, drop {
    package_version_id: ID,
    package_admin_id: ID,
    valid_pause_bits: u8,
    paused: u8,
    package_witness: TypeName,
    version: u64,
}

public struct PackageAdminCreated<phantom OTW: drop> has copy, drop {
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    original_package_id: ID,
    upgrade_cap_version: u64,
    policy: u8,
}

public struct UpgradeAuthorized<phantom OTW: drop> has copy, drop {
    package_admin_id: ID,
    upgrade_cap_id: ID,
    current_package_id: ID,
    upgrade_cap_version: u64,
    policy: u8,
    digest: vector<u8>,
}

public struct UpgradeCommitted<phantom OTW: drop> has copy, drop {
    package_admin_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    new_package_id: ID,
    previous_upgrade_cap_version: u64,
    new_upgrade_cap_version: u64,
}

public struct UpgradeCapDestroyed<phantom OTW: drop> has copy, drop {
    package_admin_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    final_upgrade_cap_version: u64,
    final_policy: u8,
}

/// Pause bits were set on a package version; `paused` is the resulting mask.
public struct Paused<phantom OTW: drop> has copy, drop {
    package_version_id: ID,
    bits: u8,
    paused: u8,
}

/// Pause bits were cleared on a package version; `paused` is the resulting mask.
public struct Unpaused<phantom OTW: drop> has copy, drop {
    package_version_id: ID,
    bits: u8,
    paused: u8,
}

// === Package Functions ===

public(package) fun paused<OTW: drop>(package_version_id: ID, bits: u8, paused: u8) {
    sui::event::emit(Paused<OTW> { package_version_id, bits, paused });
}

public(package) fun unpaused<OTW: drop>(package_version_id: ID, bits: u8, paused: u8) {
    sui::event::emit(Unpaused<OTW> { package_version_id, bits, paused });
}

public(package) fun admin_granted(admin_cap_id: ID, recipient: address) {
    sui::event::emit(AdminGranted { admin_cap_id, recipient });
}

public(package) fun admin_revoked(admin_cap_id: ID, roles: vector<TypeName>) {
    sui::event::emit(AdminRevoked { admin_cap_id, roles });
}

public(package) fun admin_role_granted(admin_cap_id: ID, role: TypeName) {
    sui::event::emit(AdminRoleGranted { admin_cap_id, role });
}

public(package) fun admin_role_revoked(admin_cap_id: ID, role: TypeName) {
    sui::event::emit(AdminRoleRevoked { admin_cap_id, role });
}

public(package) fun admin_destroyed(admin_cap_id: ID, roles: vector<TypeName>, was_active: bool) {
    sui::event::emit(AdminDestroyed { admin_cap_id, roles, was_active });
}

public(package) fun super_admin_transferred(
    previous_super_admin_cap_id: ID,
    new_super_admin_cap_id: ID,
    recipient: address,
) {
    sui::event::emit(SuperAdminTransferred {
        previous_super_admin_cap_id,
        new_super_admin_cap_id,
        recipient,
    });
}

public(package) fun super_admin_cap_destroyed(super_admin_cap_id: ID) {
    sui::event::emit(SuperAdminCapDestroyed { super_admin_cap_id });
}

public(package) fun version_advanced<OTW: drop>(
    container_id: ID,
    original_package_id: address,
    previous_version: u64,
    new_version: u64,
) {
    sui::event::emit(VersionAdvanced<OTW> {
        container_id,
        original_package_id,
        previous_version,
        new_version,
    });
}

public(package) fun package_version_created<OTW: drop>(
    package_version_id: ID,
    package_admin_id: ID,
    valid_pause_bits: u8,
    paused: u8,
    package_witness: TypeName,
    version: u64,
) {
    sui::event::emit(PackageVersionCreated<OTW> {
        package_version_id,
        package_admin_id,
        valid_pause_bits,
        paused,
        package_witness,
        version,
    });
}

public(package) fun package_admin_created<OTW: drop>(
    package_admin_id: ID,
    publisher_id: ID,
    upgrade_cap_id: ID,
    original_package_id: ID,
    upgrade_cap_version: u64,
    policy: u8,
) {
    sui::event::emit(PackageAdminCreated<OTW> {
        package_admin_id,
        publisher_id,
        upgrade_cap_id,
        original_package_id,
        upgrade_cap_version,
        policy,
    });
}

public(package) fun upgrade_authorized<OTW: drop>(
    package_admin_id: ID,
    upgrade_cap_id: ID,
    current_package_id: ID,
    upgrade_cap_version: u64,
    policy: u8,
    digest: vector<u8>,
) {
    sui::event::emit(UpgradeAuthorized<OTW> {
        package_admin_id,
        upgrade_cap_id,
        current_package_id,
        upgrade_cap_version,
        policy,
        digest,
    });
}

public(package) fun upgrade_committed<OTW: drop>(
    package_admin_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    new_package_id: ID,
    previous_upgrade_cap_version: u64,
    new_upgrade_cap_version: u64,
) {
    sui::event::emit(UpgradeCommitted<OTW> {
        package_admin_id,
        upgrade_cap_id,
        original_package_id,
        new_package_id,
        previous_upgrade_cap_version,
        new_upgrade_cap_version,
    });
}

public(package) fun upgrade_cap_destroyed<OTW: drop>(
    package_admin_id: ID,
    upgrade_cap_id: ID,
    original_package_id: address,
    final_upgrade_cap_version: u64,
    final_policy: u8,
) {
    sui::event::emit(UpgradeCapDestroyed<OTW> {
        package_admin_id,
        upgrade_cap_id,
        original_package_id,
        final_upgrade_cap_version,
        final_policy,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun collect_one<Event: copy + drop>(abort_code: u64): Event {
    let mut events = sui::event::events_by_type<Event>();
    assert!(events.length() == 1, abort_code);
    events.pop_back()
}

#[test_only]
public fun admin_granted_fields(self: &AdminGranted): (ID, address) {
    (self.admin_cap_id, self.recipient)
}

#[test_only]
public fun admin_revoked_fields(self: &AdminRevoked): (ID, vector<TypeName>) {
    (self.admin_cap_id, self.roles)
}

#[test_only]
public fun admin_role_granted_fields(self: &AdminRoleGranted): (ID, TypeName) {
    (self.admin_cap_id, self.role)
}

#[test_only]
public fun admin_role_revoked_fields(self: &AdminRoleRevoked): (ID, TypeName) {
    (self.admin_cap_id, self.role)
}

#[test_only]
public fun admin_destroyed_fields(self: &AdminDestroyed): (ID, vector<TypeName>, bool) {
    (self.admin_cap_id, self.roles, self.was_active)
}

#[test_only]
public fun super_admin_transferred_fields(self: &SuperAdminTransferred): (ID, ID, address) {
    (self.previous_super_admin_cap_id, self.new_super_admin_cap_id, self.recipient)
}

#[test_only]
public fun super_admin_cap_destroyed_fields(self: &SuperAdminCapDestroyed): ID {
    self.super_admin_cap_id
}

#[test_only]
public fun version_advanced_fields<OTW: drop>(
    self: &VersionAdvanced<OTW>,
): (ID, address, u64, u64) {
    (
        self.container_id,
        self.original_package_id,
        self.previous_version,
        self.new_version,
    )
}

#[test_only]
public fun package_version_created_fields<OTW: drop>(
    self: &PackageVersionCreated<OTW>,
): (ID, ID, u8, u8, TypeName, u64) {
    (
        self.package_version_id,
        self.package_admin_id,
        self.valid_pause_bits,
        self.paused,
        self.package_witness,
        self.version,
    )
}

#[test_only]
public fun package_admin_created_fields<OTW: drop>(
    self: &PackageAdminCreated<OTW>,
): (ID, ID, ID, ID, u64, u8) {
    (
        self.package_admin_id,
        self.publisher_id,
        self.upgrade_cap_id,
        self.original_package_id,
        self.upgrade_cap_version,
        self.policy,
    )
}

#[test_only]
public fun upgrade_authorized_fields<OTW: drop>(
    self: &UpgradeAuthorized<OTW>,
): (ID, ID, ID, u64, u8, vector<u8>) {
    (
        self.package_admin_id,
        self.upgrade_cap_id,
        self.current_package_id,
        self.upgrade_cap_version,
        self.policy,
        self.digest,
    )
}

#[test_only]
public fun upgrade_committed_fields<OTW: drop>(
    self: &UpgradeCommitted<OTW>,
): (ID, ID, address, ID, u64, u64) {
    (
        self.package_admin_id,
        self.upgrade_cap_id,
        self.original_package_id,
        self.new_package_id,
        self.previous_upgrade_cap_version,
        self.new_upgrade_cap_version,
    )
}

#[test_only]
public fun upgrade_cap_destroyed_fields<OTW: drop>(
    self: &UpgradeCapDestroyed<OTW>,
): (ID, ID, address, u64, u8) {
    (
        self.package_admin_id,
        self.upgrade_cap_id,
        self.original_package_id,
        self.final_upgrade_cap_version,
        self.final_policy,
    )
}

#[test_only]
public fun paused_fields<OTW: drop>(self: &Paused<OTW>): (ID, u8, u8) {
    (self.package_version_id, self.bits, self.paused)
}

#[test_only]
public fun unpaused_fields<OTW: drop>(self: &Unpaused<OTW>): (ID, u8, u8) {
    (self.package_version_id, self.bits, self.paused)
}

// === Imports ===

use std::type_name::TypeName;
