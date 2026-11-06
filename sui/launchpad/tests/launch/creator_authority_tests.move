// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Creator recipients and the claim they authorize. Address claims through a launch are covered in
/// `launch_tests`; this suite proves the Blast account attestation.
module blast_fun::creator_authority_tests;

// === Constants ===

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const NOW_AT_MS: u64 = 1_000_000;

const EXPIRES_AT_MS: u64 = 2_000_000;

/// The fixture's signer delay.
const DELAY_MS: u64 = 172_800_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;

public struct OTHER_MEME() has drop;

/// A runtime configuration whose first signer is live and a clock at `NOW_AT_MS`.
public struct ClaimFixture {
    scenario: Scenario,
    package_version: PackageVersion<BLAST_FUN>,
    config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

// --- Recipients ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::creator_authority)]
fun address_recipient_rejects_the_zero_address() {
    creator_authority::new_address(@0x0);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidAccountCommitment, location = blast_fun::creator_authority)]
fun account_recipient_rejects_a_commitment_that_is_not_32_bytes() {
    creator_authority::new_account(x"1122");
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun address_claim_rejects_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(creator_authority::new_address(CREATOR), option::some(attestation()));
    });

    fixture.end();
}

// --- Account claims ---

#[test]
/// The backend signs the domain tag followed by the BCS claim message binding the Meme type, the
/// account, the claimant, and the expiry; the claimant presents it and receives both caps.
fun account_claim_with_the_backend_signature_issues_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(
            creator_authority::creator_claim_message_bytes_for_testing<TEST_MEME>(
                account_commitment(),
                CREATOR,
                EXPIRES_AT_MS,
            ),
            if (@blast_fun == @0x0) x"626c6173745f66756e3a3a63726561746f725f636c61696d3a3a763164303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000"
            else x"626c6173745f66756e3a3a63726561746f725f636c61696d3a3a763164303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
        );

        let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<TEST_MEME>(
            account_recipient(),
            &f.config.creator_claim_signers(),
            option::some(attestation()),
            &f.clock,
            f.ctx!(),
        );

        assert!(object::id(&curve_fee_cap) != object::id(&metadata_cap));
        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_creator_metadata_cap();
    });

    fixture.end();
}

#[test]
fun account_claim_is_accepted_at_the_expiry() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRES_AT_MS);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun account_claim_requires_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::none());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_that_is_not_64_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut signature = signature();
        signature.pop_back();
        let attestation = creator_authority::new_creator_claim_attestation_for_testing(
            EXPIRES_AT_MS,
            signature,
        );

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun account_claim_rejects_trailing_attestation_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut attestation = attestation();
        attestation.push_back(0);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorClaimExpired, location = blast_fun::creator_authority)]
fun account_claim_rejects_an_expired_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRES_AT_MS + 1);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_claimant() {
    let mut fixture = start();

    fixture.next_tx!(@0xBAD, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_meme() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<OTHER_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_account() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let other_account = creator_authority::new_account(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );

        f.claim<TEST_MEME>(other_account, option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// A signature over the bare BCS claim, without the domain tag, does not authorize the claim.
fun account_claim_rejects_a_signature_without_the_domain_tag() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let attestation = creator_authority::new_creator_claim_attestation_for_testing(
            EXPIRES_AT_MS,
            untagged_signature(),
        );

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

// --- Signer set ---

#[test]
/// Any admitted key verifies: the second key's attestation claims while the first stays live.
fun account_claim_signed_by_the_second_admitted_key_issues_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.admit_creator_claim_signer(second_signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(f.config.creator_claim_signers(), vector[signer_public_key(), second_signer_public_key()]);

        f.claim<TEST_MEME>(account_recipient(), option::some(second_attestation()));
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// A pending key signs nothing until its delay has passed and it is applied.
fun account_claim_rejects_an_attestation_from_a_pending_key() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = blast_acl::witness_for_testing<ClaimSignerAdmin>();
        f.config.schedule_creator_claim_signer(
            &f.package_version,
            &admin_witness,
            second_signer_public_key(),
            &f.clock,
        );
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(second_attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// An attestation the first key signed before its revocation stops verifying, even while the
/// rotated-in key keeps the set non-empty.
fun account_claim_rejects_an_attestation_signed_before_its_key_was_revoked() {
    let mut fixture = start();
    let attestation = attestation();

    fixture.next_tx!(ADMIN, |f| {
        f.admit_creator_claim_signer(second_signer_public_key());
        f.revoke_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(f.config.creator_claim_signers(), vector[second_signer_public_key()]);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test]
/// Rotation needs no downtime: after the first key is revoked, the second still signs.
fun account_claim_after_rotation_verifies_with_the_remaining_key() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.admit_creator_claim_signer(second_signer_public_key());
        f.revoke_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(second_attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// With no admitted key, even a correctly signed attestation fails.
fun account_claim_rejects_every_attestation_when_the_signer_set_is_empty() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.revoke_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        assert!(f.config.creator_claim_signers().is_empty());

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test]
fun readmitting_a_revoked_key_reenables_its_attestations() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.revoke_creator_claim_signer(signer_public_key());
        f.admit_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

// === Test Helpers ===

macro fun claim_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun claim_ctx($fixture: &mut ClaimFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): ClaimFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let package_version = package_version::version_for_testing(scenario.ctx());
    let config = runtime_config::new_zero_fee_share_with_signer_for_testing(signer_public_key(), scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_AT_MS);

    ClaimFixture { scenario, package_version, config, clock }
}

/// Claims as the current sender against the admitted signer keys and discards both caps.
fun claim_claim<Meme>(
    self: &mut ClaimFixture,
    recipient: CreatorRecipient,
    attestation: Option<vector<u8>>,
) {
    let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<Meme>(
        recipient,
        &self.config.creator_claim_signers(),
        attestation,
        &self.clock,
        self.scenario.ctx(),
    );

    curve_fee_cap.destroy_curve_fee_cap();
    metadata_cap.destroy_creator_metadata_cap();
}

/// Schedules `signer_public_key` and admits it once a synthetic clock has waited the delay,
/// leaving the fixture clock at `NOW_AT_MS` so attestations stay unexpired.
fun claim_admit_creator_claim_signer(self: &mut ClaimFixture, signer_public_key: vector<u8>) {
    let admin_witness = blast_acl::witness_for_testing<ClaimSignerAdmin>();
    let mut admin_clock = clock::create_for_testing(self.scenario.ctx());

    self.config.schedule_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key, &admin_clock);
    admin_clock.set_for_testing(DELAY_MS);
    self.config.apply_creator_claim_signer(&self.package_version, signer_public_key, &admin_clock);
    destroy(admin_clock);
}

fun claim_revoke_creator_claim_signer(self: &mut ClaimFixture, signer_public_key: vector<u8>) {
    let admin_witness = blast_acl::witness_for_testing<ClaimSignerAdmin>();

    self.config.revoke_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key);
}

fun claim_end(self: ClaimFixture) {
    destroy(self);
}

fun account_recipient(): CreatorRecipient {
    creator_authority::new_account(account_commitment())
}

/// The backend's attestation for `CREATOR` claiming `TEST_MEME` for `account_commitment()`.
fun attestation(): vector<u8> {
    creator_authority::new_creator_claim_attestation_for_testing(EXPIRES_AT_MS, signature())
}

fun account_commitment(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

// Public test fixture: Ed25519 seed [7; 32], signing the tagged message above for
// the manifest address 0x0 or the fresh-stack harness address 0xc. Never used outside tests.
fun signer_public_key(): vector<u8> {
    x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
}

fun signature(): vector<u8> {
    if (@blast_fun == @0x0) x"d9bbf4981405528afbf81bf2577214ed16005848c05557b2e7632ee8d75202dd3cf30a33dee9cc5eb2edb1d5bd4c5b70b18b502327abced24787bafed5b2ce0a"
    else x"3fb85e420aec61b9cf441af24cbc48bf5cbc7ce7fb3b116327f04ac9a86c9cd6fa2598296fd39611234edbf61eeccc2993cb083a88c5d6de464920df06f82102"
}

/// The same claim signed by the second signer key.
fun second_attestation(): vector<u8> {
    creator_authority::new_creator_claim_attestation_for_testing(EXPIRES_AT_MS, second_signature())
}

// Public test fixture: Ed25519 seed [8; 32], signing the same tagged message. Never used outside
// tests.
fun second_signer_public_key(): vector<u8> {
    x"1398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca"
}

fun second_signature(): vector<u8> {
    if (@blast_fun == @0x0) x"11c7fa924bbdf8d1bf920e8facc6ce51e0eb8c5c30df8335550bc6a7e003ffe7a96c08f911795aadeeb6fae457ac43af7fdf63b8aa5ad456332b44e746a9b20f"
    else x"5e17e9f22982da21fde818ea7118d21915cd41a54c5746443bc9a37d24832ec03f00253eb58b4c34a1acc1df837537247076102f271496e01e6819492da7b10e"
}

/// Seed [7; 32]'s signature over the same claim without the domain tag.
fun untagged_signature(): vector<u8> {
    if (@blast_fun == @0x0) x"2bcd04128bf27019d5f9bc462e15e447124540f78796879c3f9f74cdd22582dab80cd2e0fc1acd676de69328026f2dbe0a5b466569c95a895306520e4bb5eb0a"
    else x"ff0ced0a7390306e2da4210845558a93f6594f4c30836e2499ad400e38a9fbadc4591d9188fa6aaaac9ff3575a7c212f62fc451d1266ea744b847b4c7afc6a04"
}

// === Imports ===

use blast_core::blast_domain::ClaimSignerAdmin;

use blast_admin::{blast_acl, package_version::PackageVersion};

use blast_fun::{
    creator_authority::{Self, CreatorRecipient},
    blast_fun::{Self as package_version, BLAST_FUN},
    runtime_config::{Self, RuntimeConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

use fun claim_admit_creator_claim_signer as ClaimFixture.admit_creator_claim_signer;

use fun claim_claim as ClaimFixture.claim;

use fun claim_ctx as ClaimFixture.ctx;

use fun claim_end as ClaimFixture.end;

use fun claim_next_tx as ClaimFixture.next_tx;

use fun claim_revoke_creator_claim_signer as ClaimFixture.revoke_creator_claim_signer;
