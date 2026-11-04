// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::merkle_tests;

// === Tests ===

#[test]
fun every_leaf_of_an_odd_tree_proves_with_its_positional_path() {
    // Three leaves: the odd third leaf is its own sibling at the first level.
    let (a, b, c) = (leaf(1), leaf(2), leaf(3));
    let (ab, cc) = (merkle::node(a, b), merkle::node(c, c));
    let root = merkle::node(ab, cc);

    assert!(merkle::verify(root, a, 0, 3, &vector[b, cc]));
    assert!(merkle::verify(root, b, 1, 3, &vector[a, cc]));
    assert!(merkle::verify(root, c, 2, 3, &vector[c, ab]));
    assert!(!merkle::verify(root, c, 2, 3, &vector[ab]));
}

#[test]
/// The SDK's three-holder vector (the migrators' holder-reward leaves): Alice's two-level proof
/// and Carol's odd leaf, which is its own sibling, verify against the SDK root.
fun the_sdk_three_holder_vector_verifies() {
    let root = x"93f46ab27a1d3a5def3379afd0a3b02cc149d6fa03b7105b2697deba8c12cb2d";
    let alice = x"18ba1db53bc0da39eb6f1f00df49fa5be0932e85ca8f8257f4d278edea7f1aa8";
    let alice_proof = vector[
        x"f0290d0717f5ac2c221a66e27d80e3c76a9ea2774a7dc7399cc5d108633526f1",
        x"4fd4325f78a40a6972b998c35cf40ec26237d6ff9e5dc2934fb882b9aa18e08a",
    ];
    assert!(merkle::verify(root, alice, 0, 3, &alice_proof));

    // The leaf helper reproduces the SDK's leaves from their fields.
    let vault = object::id_from_address(@0xD);
    assert_eq!(rewards_leaf(vault, 0, @0xA, 10, 20), alice);
    let bob = rewards_leaf(vault, 1, @0xB, 30, 40);
    let carol = rewards_leaf(vault, 2, @0xC, 50, 60);
    assert_eq!(bob, alice_proof[0]);
    let ab = x"ca047224c2edac2b2dcd7f28d0a6d6c7175a2f10beef5f440b0597d0e1c7a7f5";
    assert_eq!(merkle::node(alice, bob), ab);
    assert_eq!(merkle::node(carol, carol), alice_proof[1]);
    assert!(merkle::verify(root, carol, 2, 3, &vector[carol, ab]));
}

#[test]
fun a_single_leaf_is_its_own_root() {
    assert!(merkle::verify(leaf(7), leaf(7), 0, 1, &vector[]));
}

#[test]
fun malformed_inputs_and_wrong_positions_fail_without_aborting() {
    let (a, b) = (leaf(1), leaf(2));
    let root = merkle::node(a, b);

    assert!(!merkle::verify(root, b, 0, 2, &vector[a]));
    assert!(!merkle::verify(root, a, 2, 2, &vector[b]));
    assert!(!merkle::verify(root, a, 0, 0, &vector[b]));
    assert!(!merkle::verify(root, a, 0, 2, &vector[]));
    assert!(!merkle::verify(root, a, 0, 2, &vector[b, b]));
    assert!(!merkle::verify(root, a, 0, 2, &vector[vector[1u8]]));
    assert!(!merkle::verify(vector[0u8], a, 0, 2, &vector[b]));
    assert!(!merkle::verify(root, vector[0u8], 0, 2, &vector[b]));
}

#[test]
fun an_internal_node_cannot_pass_as_a_leaf_of_a_deeper_tree() {
    let (a, b, c, d) = (leaf(1), leaf(2), leaf(3), leaf(4));
    let (ab, cd) = (merkle::node(a, b), merkle::node(c, d));
    let root = merkle::node(ab, cd);

    // `ab` proves only at the depth of its own subtree.
    assert!(!merkle::verify(root, ab, 0, 4, &vector[cd]));
    assert!(merkle::verify(root, ab, 0, 2, &vector[cd]));
}

// === Test Helpers ===

fun rewards_leaf(vault: ID, index: u64, beneficiary: address, meme: u64, quote: u64): vector<u8> {
    let mut payload = bcs::to_bytes(&vault);
    payload.append(bcs::to_bytes(&0u64));
    payload.append(bcs::to_bytes(&index));
    payload.append(bcs::to_bytes(&beneficiary));
    payload.append(bcs::to_bytes(&meme));
    payload.append(bcs::to_bytes(&quote));

    merkle::leaf(b"blast-holder-rewards-v1", payload)
}

fun leaf(value: u8): vector<u8> {
    sui::hash::blake2b256(&vector[0u8, value])
}

// === Imports ===

use blast_core::merkle;

use std::{bcs, unit_test::assert_eq};
