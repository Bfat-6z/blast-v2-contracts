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
    assert_eq!(errors::version_mismatch!(), 9);
    assert_eq!(errors::invalid_upgrade_cap!(), 10);
    assert_eq!(errors::invalid_package_digest!(), 11);
    assert_eq!(errors::upgrade_cap_unavailable!(), 12);
    assert_eq!(errors::not_ready!(), 13);
    assert_eq!(errors::no_pending!(), 14);
    assert_eq!(errors::invalid_delay!(), 15);
    assert_eq!(errors::unchanged!(), 16);
    assert_eq!(errors::proposal_pending!(), 17);
    assert_eq!(errors::wrong_change!(), 18);
    assert_eq!(errors::invalid_pause_bits!(), 19);
    assert_eq!(errors::pause_unchanged!(), 20);
    assert_eq!(errors::paused!(), 21);
    assert_eq!(errors::wrong_upgrade_action!(), 22);
    assert_eq!(errors::unguarded_upgrade_notice!(), 23);
    assert_eq!(errors::invalid_package_witness!(), 24);
    assert_eq!(errors::wrong_unpause_witness!(), 25);
    assert_eq!(errors::wrong_package_witness!(), 26);
}

// === Imports ===

use blast_admin::errors;

use std::unit_test::assert_eq;
