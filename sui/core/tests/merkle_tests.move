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

fun leaf(value: u8): vector<u8> {
    sui::hash::blake2b256(&vector[0u8, value])
}

// === Imports ===

use blast_core::merkle;
