// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Pins the shared administration error registry.
module blast_admin::errors_tests;

// === Tests ===

#[test]
fun shared_error_codes_are_stable() {
    assert_eq!(errors::invalid_super_admin_cap!(), 0);
    assert_eq!(errors::invalid_admin_cap!(), 1);
    assert_eq!(errors::invalid_admin_recipient!(), 2);
    assert_eq!(errors::admin_role_capacity_reached!(), 3);
    assert_eq!(errors::admin_role_already_granted!(), 4);
    assert_eq!(errors::admin_role_not_granted!(), 5);
    assert_eq!(errors::invalid_super_admin_recipient!(), 6);
    assert_eq!(errors::not_pending_super_admin_recipient!(), 7);
    assert_eq!(errors::super_admin_cap_still_active!(), 8);
    assert_eq!(errors::operational_version_mismatch!(), 9);
    assert_eq!(errors::operational_version_overflow!(), 10);
    assert_eq!(errors::invalid_package_publisher!(), 11);
    assert_eq!(errors::invalid_upgrade_cap!(), 12);
    assert_eq!(errors::invalid_package_digest!(), 13);
    assert_eq!(errors::upgrade_cap_unavailable!(), 14);
    assert_eq!(errors::upgrade_policy_not_more_restrictive!(), 15);
    assert_eq!(errors::invalid_package_marker!(), 16);
    assert_eq!(errors::not_ready!(), 17);
    assert_eq!(errors::no_pending!(), 18);
    assert_eq!(errors::invalid_delay!(), 19);
    assert_eq!(errors::unchanged!(), 20);
    assert_eq!(errors::proposal_pending!(), 21);
    assert_eq!(errors::wrong_change!(), 22);
    assert_eq!(errors::invalid_pause_bits!(), 23);
    assert_eq!(errors::pause_unchanged!(), 24);
    assert_eq!(errors::paused!(), 25);
    assert_eq!(errors::wrong_upgrade_action!(), 26);
    assert_eq!(errors::unguarded_upgrade_notice!(), 27);
    assert_eq!(errors::invalid_package_witness!(), 28);
}

// === Imports ===

use blast_admin::errors;

use std::unit_test::assert_eq;
