//! Programmable-transaction integration tests for launch creation, the atomic migration seam, and
//! the opening round.
//!
//! Every launch is opened by one PTB composed from public calls: the mock adapter starts it under
//! its own witness and pool tier, the launchpad setters configure the initializer, and `finalize`
//! and `share` consume it, so the ability-less initializer crosses commands of one transaction.
//!
//! Two independent one-time-witness launches reach MigrationReady through public PTBs. Every
//! failing migration PTB must commit nothing (see `Harness::assert_rolled_back`): no allocation
//! reaches the launch ledger or the creator's recipient, and launch A stays migratable through the
//! whole failure matrix before completing in one successful PTB. Every event travels in the
//! launchpad envelope.
//!
//! A launch with an opening round shows the launch-owned bidder record the first bid creates, that
//! nothing trades or pays out before settlement, that every failing round call commits nothing,
//! the pot's one purchase at settlement, and the delivery that retires the record; each step's
//! storage cost is printed.
//!
//! LP-fee splits that sum to zero or name seventeen recipients abort in the fee-split constructor
//! before the launch exists, while sixteen recipients commit unchanged into the launch. A split
//! with every part and sixteen distinct recipient weights is measured at creation and migration;
//! each record prints as one `LAUNCH_FEE_SPLIT_CAPACITY` JSON line with its margins to the
//! simulator's protocol limits. Recurring LP-fee collection and split updates belong to the
//! migrators package.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test` (needs the pinned `sui` on PATH).

use std::{collections::BTreeSet, path::Path, time::Duration};

use anyhow::Result;
use blast_launchpad_ptb_tests::{
    ActionApplied, ActionScheduled, Change, CompiledPackage, Delayed, Expected, Harness, Outcome, SetApplied,
    SetChange, SetScheduled, build, build_timelock, call, sui_dir, timelock_dir,
};
use move_binary_format::{CompiledModule, file_format::SignatureToken};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    effects::TransactionEffectsAPI,
    object::Owner,
    move_package::MovePackage,
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
};

const TARGET: u64 = 25_000_000;
const BUY: u64 = 30_000_000;

/// The pool tier every launch starts at, in the mock venue's native units.
const POOL_TICK_SPACING: u32 = 60;
const POOL_FEE_RATE: u64 = 2_500;

/// `launch::set_opening_round` argument; zero leaves the launch without one and skips the call.
const NO_OPENING_ROUND: u64 = 0;
const OPENING_ROUND_MS: u64 = 60_000;
/// One opening-round bid, far below the graduation target.
const BID: u64 = 1_000_000;

/// `blast_fun::errors` codes.
const INVALID_SHARES: u64 = 7;
const RECIPIENT_CAPACITY_REACHED: u64 = 8;
const INVALID_LAUNCH_LIFECYCLE: u64 = 15;
const OPENING_ROUND_ENDED: u64 = 18;
const OPENING_ROUND_NOT_ENDED: u64 = 19;
const INVALID_CREATOR_RECIPIENT: u64 = 25;
const ZERO_OPENING_ROUND_BID: u64 = 34;
const INVALID_PAUSE_BITS: u64 = 38;
const PAUSE_UNCHANGED: u64 = 39;

const DESTINATION: ObjectID = address(&[0xD5]);
/// Blast's one-time share of both the Meme supply and the final Quote reserve.
const BLAST_BPS: u64 = 500;

const fn address(suffix: &[u8]) -> ObjectID {
    let mut bytes = [0u8; 32];
    let mut index = 0;
    while index < suffix.len() {
        bytes[32 - suffix.len() + index] = suffix[index];
        index += 1;
    }
    ObjectID::new(bytes)
}

struct Launch {
    meme: TypeTag,
    launch: ObjectID,
    currency: ObjectID,
}

struct World {
    h: Harness,
    blast: ObjectID,
    adapter: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    project: CompiledPackage,
    core_code: CompiledPackage,
    adapter_code: CompiledPackage,
    admin: ObjectID,
    acl: ObjectID,
    root: ObjectID,
    admin_cap: ObjectID,
    custody: ObjectID,
}

const ADMIN_DELAY_MS: u64 = 172_800_000;

#[test]
fn administration_notice_cancellation_revocation_and_ptb_rollback() -> Result<()> {
    let mut w = world("admin-security")?;
    w.change_role("CancelAdmin", true)?;
    let destination: SuiAddress = address(&[0xCA, 0xFE]).into();
    w.h.execute(w.schedule_treasury(destination)?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS - 1));
    let watched = [w.runtime, w.config, w.acl, w.admin_cap];
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_treasury", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 17 }, &watched, &[w.h.sender])?;
    w.h.sim.advance_clock(Duration::from_millis(1));

    // Apply a ready treasury, emit its event, then fail a different not-ready action.
    // The failed PTB must preserve the original treasury AND the still-pending proposal.
    let mut b = ProgrammableTransactionBuilder::new();
    let fee_admin = w.sign_in(&mut b, "FeeAdmin")?;
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    let fee = b.pure(123u64)?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = b.pure(172_800_000u64)?;
    call(&mut b, w.blast, "launch_config", "schedule_creation_fee", vec![], vec![config, version, fee_admin, fee, next_delay, clock]);
    w.h.execute(b.finish())?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let runtime = b.obj(w.h.shared(w.runtime, true))?;
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.blast, "runtime_config", "apply_treasury", vec![], vec![runtime, version, clock]);
    call(&mut b, w.blast, "launch_config", "apply_creation_fee", vec![], vec![config, version, clock]);
    w.h.assert_rolled_back(b.finish(), Expected::Abort { package: w.admin, module: "delayed", code: 17 }, &watched, &[w.h.sender])?;

    w.change_role("TreasuryAdmin", false)?;
    w.h.assert_rolled_back(w.schedule_treasury(address(&[0xAB]).into())?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    // Revocation intentionally does not cancel a proposal. Apply requires no cap or role.
    w.h.execute(w.apply_setting("runtime_config", "apply_treasury", w.runtime)?)?.assert_success();
    assert_eq!(w.applied_treasury()?, destination);
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_treasury", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 18 }, &watched, &[w.h.sender])?;

    w.change_role("TreasuryAdmin", true)?;
    w.h.execute(w.schedule_treasury(address(&[0xAB]).into())?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS));
    let mut b = ProgrammableTransactionBuilder::new();
    let cancel = w.sign_in(&mut b, "CancelAdmin")?;
    let runtime = b.obj(w.h.shared(w.runtime, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    call(&mut b, w.blast, "runtime_config", "cancel_treasury", vec![], vec![runtime, version, cancel]);
    w.h.execute(b.finish())?.assert_success();
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_treasury", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 18 }, &watched, &[w.h.sender])?;
    assert_eq!(w.applied_treasury()?, destination);
    Ok(())
}

#[test]
fn adapter_admission_order_preserves_policy_and_pending_deadlines() -> Result<()> {
    let mut w = world("adapter-policy-order")?;
    for (policy_first, old_delay, next_delay) in [
        (true, ADMIN_DELAY_MS, 100u64),
        (false, 100u64, 25u64),
    ] {
        let first = w.h.publish(w.adapter_code.clone())?.0;
        let second = w.h.publish(w.adapter_code.clone())?.0;
        let adapters = [first, second].map(|id| {
            parse_sui_type_tag(&format!("{id}::mock_adapter::Venue")).unwrap()
        });
        let mut b = ProgrammableTransactionBuilder::new();
        let admin = w.sign_in(&mut b, "AdapterAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        for adapter in &adapters {
            call(&mut b, w.blast, "launch_config", "schedule_migration_witness",
                vec![adapter.clone()], vec![config, version, admin, clock]);
        }
        let delay = b.pure(next_delay)?;
        call(&mut b, w.blast, "launch_config", "schedule_migration_delay",
            vec![], vec![config, version, admin, delay, clock]);
        w.h.execute(b.finish())?.assert_success();

        let mut apply = ProgrammableTransactionBuilder::new();
        let config = apply.obj(w.h.shared(w.config, true))?;
        let version = apply.obj(w.h.shared(w.version, false))?;
        let clock = apply.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        if policy_first {
            call(&mut apply, w.blast, "launch_config", "apply_migration_delay",
                vec![], vec![config, version, clock]);
        }
        for adapter in adapters.iter().rev() {
            call(&mut apply, w.blast, "launch_config", "apply_migration_witness",
                vec![adapter.clone()], vec![config, version, clock]);
        }
        if !policy_first {
            call(&mut apply, w.blast, "launch_config", "apply_migration_delay",
                vec![], vec![config, version, clock]);
        }
        let apply = apply.finish();
        let watched = [w.config, w.version, w.acl, w.admin_cap];
        w.h.sim.advance_clock(Duration::from_millis(old_delay - 1));
        // The first early step aborts: a notice change through the shared readiness check, an
        // admission in the set itself.
        let early_module = if policy_first { "delayed" } else { "delayed_set" };
        w.h.assert_rolled_back(apply.clone(),
            Expected::Abort { package: w.admin, module: early_module, code: 17 },
            &watched, &[w.h.sender])?;
        w.h.sim.advance_clock(Duration::from_millis(1));
        let applied = w.h.execute(apply)?;
        applied.assert_success();
        // The primitive records the notice change and each admission, in application order.
        assert!(applied.wrapped_payloads(w.blast).is_empty());
        let changes: Vec<SetApplied<String>> =
            applied.delayed("SetApplied", "launch_config", "MigrationWitnessKey")?;
        let admitted: Vec<_> = adapters.iter().rev()
            .map(|adapter| SetChange::Admission(adapter.to_canonical_string(false))).collect();
        let expected: Vec<_> = if policy_first {
            std::iter::once(SetChange::Delay).chain(admitted).collect()
        } else {
            admitted.into_iter().chain(std::iter::once(SetChange::Delay)).collect()
        };
        assert_eq!(changes.iter().map(|applied| applied.change.clone()).collect::<Vec<_>>(), expected);
        assert!(changes.iter().all(|applied| applied.owner == w.config));
        assert_eq!(changes.iter().find(|applied| applied.change == SetChange::Delay).map(|applied| applied.delay_ms),
            Some(next_delay));

        // A fresh admission uses the new policy, even after applying older admissions.
        let later = w.h.publish(w.adapter_code.clone())?.0;
        let later = parse_sui_type_tag(&format!("{later}::mock_adapter::Venue"))?;
        let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let mut b = ProgrammableTransactionBuilder::new();
        let admin = w.sign_in(&mut b, "AdapterAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch_config", "schedule_migration_witness",
            vec![later.clone()], vec![config, version, admin, clock]);
        let scheduled = w.h.execute(b.finish())?;
        scheduled.assert_success();
        let admissions: Vec<SetScheduled<String>> =
            scheduled.delayed("SetScheduled", "launch_config", "MigrationWitnessKey")?;
        assert_eq!(admissions.len(), 1);
        assert_eq!(admissions[0].change, SetChange::Admission(later.to_canonical_string(false)));
        assert_eq!((admissions[0].ready_at_ms, admissions[0].delay_ms), (now + next_delay, next_delay));

        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch_config", "apply_migration_witness",
            vec![later], vec![config, version, clock]);
        let apply = b.finish();
        w.h.sim.advance_clock(Duration::from_millis(next_delay - 1));
        w.h.assert_rolled_back(apply.clone(),
            Expected::Abort { package: w.admin, module: "delayed_set", code: 17 },
            &watched, &[w.h.sender])?;
        w.h.sim.advance_clock(Duration::from_millis(1));
        w.h.execute(apply)?.assert_success();
    }
    Ok(())
}

#[test]
fn pause_rolls_back_creation_trading_and_migration_but_allows_delivery() -> Result<()> {
    let mut w = world("pause-security")?;
    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    let round = w.open_launch(OPENING_ROUND_MS)?;
    w.h.execute(w.join(&round, BID)?)?.assert_success();
    let ready = w.open_launch(NO_OPENING_ROUND)?;
    w.buy_to_migration(&ready)?;
    let (ticket, currency, meme) = w.publish_ticket()?;
    w.set_pause(true, 7)?;
    let watched = [round.launch, ready.launch, ready.currency, ticket, currency, w.version];
    let abort = || Expected::Abort { package: w.blast, module: "blast_fun", code: 40 };
    w.h.assert_rolled_back(w.create_launch(ticket, currency, &meme, &FeeSplit::single(DESTINATION), NO_OPENING_ROUND)?, abort(), &watched, &[w.h.sender])?;
    w.h.assert_rolled_back(w.join(&round, BID)?, abort(), &watched, &[w.h.sender])?;
    w.h.assert_rolled_back(w.migrate(&ready, &ready, false)?, abort(), &watched, &[w.h.sender])?;
    w.h.sim.advance_clock(Duration::from_millis(OPENING_ROUND_MS));
    w.h.assert_rolled_back(w.settle(&round)?, abort(), &watched, &[w.h.sender])?;
    w.set_pause(false, 2)?;
    w.h.execute(w.settle(&round)?)?.assert_success();
    // Releasing trading must not release migration or creation.
    w.h.assert_rolled_back(w.migrate(&ready, &ready, false)?, Expected::Abort { package: w.blast, module: "blast_fun", code: 40 }, &watched, &[w.h.sender])?;
    w.set_pause(true, 2)?;
    let delivered = w.h.execute(w.deliver(&round, w.h.sender)?)?;
    delivered.assert_success();
    assert!(delivered.wrapped_payloads(w.blast).iter().any(|name| name == "OpeningRoundDelivered"));
    Ok(())
}

/// Every reachable pause state against every u8 input, through unmodified production bytecode.
#[test]
fn pause_exhaustively_checks_masks_events_rollback_and_version_precedence() -> Result<()> {
    let mut w = world("pause-mask-matrix")?;
    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    // A set oracle keeps expected transitions independent of the contract's bitwise formulas.
    let states: [&[u8]; 8] = [&[], &[1], &[2], &[1, 2], &[4], &[1, 4], &[2, 4], &[1, 2, 4]];
    let watched = [w.version, w.acl, w.admin_cap, w.runtime, w.config, w.custody];
    let mut successes = 0;
    let mut invalid = 0;
    let mut unchanged = 0;
    let mut stale = 0;
    for generation in [1, 2] {
        for (mask, flags) in states.iter().enumerate() {
            w.set_pause_generation_for_fixture(1)?;
            w.replace_pause_mask(mask as u8)?;
            w.set_pause_generation_for_fixture(generation)?;
            let before: BTreeSet<_> = flags.iter().copied().collect();
            for bits in 0..=u8::MAX {
                for pausing in [true, false] {
                    let requested: BTreeSet<_> = [1u8, 2, 4].into_iter()
                        .filter(|flag| (bits / flag) % 2 == 1).collect();
                    let after: BTreeSet<u8> = if pausing {
                        before.union(&requested).copied().collect()
                    } else {
                        before.difference(&requested).copied().collect()
                    };
                    let pt = w.pause_command(pausing, bits)?;
                    let rejected = if generation != 1 {
                        stale += 1;
                        Some(Expected::Abort { package: w.admin, module: "operational_version", code: 9 })
                    } else if !(1..=7).contains(&bits) {
                        invalid += 1;
                        Some(Expected::Abort { package: w.blast, module: "blast_fun", code: INVALID_PAUSE_BITS })
                    } else if after == before {
                        unchanged += 1;
                        Some(Expected::Abort { package: w.blast, module: "blast_fun", code: PAUSE_UNCHANGED })
                    } else {
                        None
                    };
                    if let Some(expected) = rejected {
                        w.h.assert_rolled_back(pt, expected, &watched, &[w.h.sender])?;
                    } else {
                        let untouched = w.h.snapshot(&watched[1..], &[w.h.sender]);
                        let outcome = w.h.execute(pt)?;
                        outcome.assert_success();
                        let name = if pausing { "Paused" } else { "Unpaused" };
                        let next: u8 = after.iter().sum();
                        assert_eq!(outcome.wrapped_payloads(w.blast), [name]);
                        assert_eq!(outcome.events_of("events", name), [vec![bits, next].as_slice()]);
                        assert_eq!(w.pause_state()?, (w.version, next, generation));
                        assert_eq!(w.h.snapshot(&watched[1..], &[w.h.sender]), untouched);
                        w.replace_pause_mask(mask as u8)?;
                        successes += 1;
                    }
                    assert_eq!(w.pause_state()?, (w.version, mask as u8, generation),
                        "pausing={pausing}, bits={bits}, initial={mask}, generation={generation}");
                }
            }
        }
    }
    assert_eq!((successes, invalid, unchanged, stale), (74, 3984, 38, 4096));
    Ok(())
}

#[test]
fn pause_roles_revocation_and_failed_sequences_preserve_state_and_events() -> Result<()> {
    let mut w = world("pause-authority")?;
    let watched = [w.version, w.acl, w.admin_cap];
    // A live AdminCap with neither role authorizes neither operation.
    for pausing in [true, false] {
        w.h.assert_rolled_back(w.pause_command(pausing, 1)?,
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    }
    w.change_role("PauseAdmin", true)?;
    w.set_pause(true, 1)?;
    w.h.assert_rolled_back(w.pause_command(false, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    let mut b = ProgrammableTransactionBuilder::new();
    w.append_pause(&mut b, false, 1, "PauseAdmin")?;
    w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &[w.h.sender])?;
    w.change_role("PauseAdmin", false)?;
    w.h.assert_rolled_back(w.pause_command(true, 2)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    w.change_role("UnpauseAdmin", true)?;
    w.set_pause(false, 1)?;
    w.h.assert_rolled_back(w.pause_command(true, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    let mut b = ProgrammableTransactionBuilder::new();
    w.append_pause(&mut b, true, 1, "UnpauseAdmin")?;
    w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &[w.h.sender])?;
    w.change_role("UnpauseAdmin", false)?;
    w.h.assert_rolled_back(w.pause_command(false, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;

    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    for (sequence, code) in [
        (vec![(true, 1), (true, 1)], PAUSE_UNCHANGED),
        (vec![(true, 1), (false, 1), (false, 1)], PAUSE_UNCHANGED),
        (vec![(true, 1), (true, 9)], INVALID_PAUSE_BITS),
    ] {
        let mut b = ProgrammableTransactionBuilder::new();
        for (pausing, bits) in sequence {
            w.append_pause(&mut b, pausing, bits, if pausing { "PauseAdmin" } else { "UnpauseAdmin" })?;
        }
        // Earlier successful commands emitted events, but the later failure commits none.
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.blast, module: "blast_fun", code }, &watched, &[w.h.sender])?;
        assert_eq!(w.pause_state()?, (w.version, 0, 1));
    }

    // Interleaved successful commands preserve native event order and replay to the final mask.
    let steps = [(true, 1, 1), (true, 3, 3), (false, 5, 2),
        (true, 4, 6), (false, 2, 4), (false, 5, 0)];
    let mut b = ProgrammableTransactionBuilder::new();
    for &(pausing, bits, _) in &steps {
        w.append_pause(&mut b, pausing, bits, if pausing { "PauseAdmin" } else { "UnpauseAdmin" })?;
    }
    let outcome = w.h.execute(b.finish())?;
    outcome.assert_success();
    let names: Vec<_> = steps.iter().map(|(pausing, _, _)| if *pausing { "Paused" } else { "Unpaused" }).collect();
    assert_eq!(outcome.wrapped_payloads(w.blast), names);
    for (event, &(_, bits, next)) in outcome.events.iter().zip(&steps) {
        assert_eq!(event.contents, [bits, next]);
    }
    assert_eq!(w.pause_state()?, (w.version, 0, 1));

    // Revoking the whole administrator defeats both roles even while it still owns its cap.
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, true))?;
    let root = b.obj(w.h.owned(w.root))?;
    let cap = b.pure(w.admin_cap)?;
    call(&mut b, w.admin, "blast_acl", "revoke_admin", vec![], vec![acl, root, cap]);
    w.h.impersonate_cap_owner(w.root, b.finish())?.assert_success();
    for pausing in [true, false] {
        w.h.assert_rolled_back(w.pause_command(pausing, 1)?,
            Expected::Abort { package: w.admin, module: "blast_acl", code: 1 }, &watched, &[w.h.sender])?;
    }
    Ok(())
}

#[test]
fn cap_recipient_schedules_enforce_live_roles_and_roll_back_failed_replacements() -> Result<()> {
    let mut w = world("cap-recipient-authority")?;
    let recipient = SuiAddress::from(DESTINATION);
    for (cap, cap_type, key, reassigned_name) in [
        ("curve_fee_cap", "CurveFeeCap", "CurveFeeCapReassignment", "CurveFeeCapReassigned"),
        ("metadata_cap", "BlastMetadataCap", "MetadataCapReassignment", "MetadataCapReassigned"),
    ] {
        let launch = w.open_launch(NO_OPENING_ROUND)?;
        let watched = [launch.launch, launch.currency, w.version, w.acl, w.admin_cap, w.config];
        let owners = [w.h.sender, recipient];
        // A real live AdminCap with other roles cannot schedule either cap replacement.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", recipient)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &owners)?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "TreasuryAdmin", recipient)?;
        w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &owners)?;

        w.change_role("CreatorAdmin", true)?;
        let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", recipient)?;
        let scheduled = w.h.execute(b.finish())?;
        scheduled.assert_success();
        assert!(scheduled.wrapped_payloads(w.blast).is_empty());
        let proposals: Vec<ActionScheduled<SuiAddress>> = scheduled.delayed("ActionScheduled", "launch", key)?;
        assert_eq!(proposals, [ActionScheduled {
            owner: launch.launch,
            key: false,
            change: Change::Action(recipient),
            delay_ms: ADMIN_DELAY_MS,
            ready_at_ms: scheduled_at_ms + ADMIN_DELAY_MS,
        }]);
        assert!(scheduled.created(&w.h, "creator_authority", "CurveFeeCap").is_empty());
        assert!(scheduled.created(&w.h, "creator_authority", "BlastMetadataCap").is_empty());

        // Invalid replacements cannot erase the already accepted recipient or its deadline.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", SuiAddress::ZERO)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.blast, module: "launch", code: INVALID_CREATOR_RECIPIENT }, &watched, &owners)?;

        // A later failing command rolls back the earlier reschedule and all its events.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", w.h.sender)?;
        let launch_arg = b.obj(w.h.shared(launch.launch, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch", &format!("apply_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, clock]);
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "delayed", code: 17 }, &watched, &owners)?;

        w.change_role("CreatorAdmin", false)?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", w.h.sender)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &owners)?;

        // Revocation blocks new schedules; accepted proposals remain permissionlessly applicable.
        w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS));
        let mut b = ProgrammableTransactionBuilder::new();
        let launch_arg = b.obj(w.h.shared(launch.launch, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch", &format!("apply_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, clock]);
        let applied = w.h.execute(b.finish())?;
        applied.assert_success();
        assert_eq!(applied.wrapped_payloads(w.blast), [reassigned_name]);
        let changes: Vec<ActionApplied<SuiAddress>> = applied.delayed("ActionApplied", "launch", key)?;
        assert_eq!(changes, [ActionApplied {
            owner: launch.launch,
            key: false,
            change: Change::Action(recipient),
            delay_ms: ADMIN_DELAY_MS,
        }]);
        let caps = applied.created(&w.h, "creator_authority", cap_type);
        assert_eq!(caps.len(), 1);
        assert_eq!(w.h.object(caps[0]).owner().get_address_owner_address()?, recipient);
        assert_eq!(applied.events_of("events", reassigned_name),
            [bcs::to_bytes(&(launch.launch, caps[0], recipient))?.as_slice()]);
        let other_cap = if cap_type == "BlastMetadataCap" { "CurveFeeCap" } else { "BlastMetadataCap" };
        assert!(applied.created(&w.h, "creator_authority", other_cap).is_empty());
    }
    Ok(())
}

#[test]
fn mixed_generation_creation_rejects_each_stale_step_after_native_upgrade() -> Result<()> {
    let mut w = world("mixed-generation-creation")?;
    let (ticket, currency, meme) = w.publish_ticket()?;
    let original = w.blast;
    let mut code = w.core_code.clone();
    for bytes in &mut code.modules {
        let mut module = CompiledModule::deserialize_with_defaults(bytes)?;
        if module.self_id().name().as_str() == "blast_fun" {
            let mut changed = 0;
            for constant in &mut module.constant_pool {
                if constant.type_ == SignatureToken::U64 {
                    let value: u64 = bcs::from_bytes(&constant.data)?;
                    if value == 1 || value == 2 {
                        constant.data = bcs::to_bytes(&(value + 1))?;
                        changed += 1;
                    }
                }
            }
            assert_eq!(changed, 2, "advance only the compiled current and next generations");
            bytes.clear();
            module.serialize_with_version(module.version, bytes)?;
        }
    }
    let role = parse_sui_type_tag(&format!("{original}::blast_fun_domain::UpgradeAdmin"))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, true))?;
    let root = b.obj(w.h.owned(w.root))?;
    let cap_id = b.pure(w.admin_cap)?;
    call(&mut b, w.admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl, root, cap_id]);
    w.h.impersonate_cap_owner(w.root, b.finish())?.assert_success();

    let custody = w.custody;
    let digest = MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true);
    let mut schedule = ProgrammableTransactionBuilder::new();
    let acl = schedule.obj(w.h.shared(w.acl, false))?;
    let cap = schedule.obj(w.h.owned(w.admin_cap))?;
    let witness = call(&mut schedule, w.admin, "blast_acl", "sign_in", vec![role.clone()], vec![acl, cap]);
    let custody_arg = schedule.obj(w.h.shared(custody, true))?;
    let version = schedule.obj(w.h.shared(w.version, false))?;
    let proposed = schedule.pure(digest.to_vec())?;
    let clock = schedule.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut schedule, original, "package_admin", "schedule_upgrade", vec![], vec![custody_arg, version, witness, proposed, clock]);
    let schedule = schedule.finish();
    let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let scheduled = w.h.execute(schedule.clone())?;
    scheduled.assert_success();
    // The primitive records the proposal, keyed by the custody's own upgrade operation.
    #[derive(Debug, Deserialize, PartialEq, Clone)]
    enum UpgradeAction { Upgrade(Vec<u8>), #[allow(dead_code)] MakeImmutable }
    let admin = w.admin;
    let upgrade_event = |name: &str| parse_sui_type_tag(&format!(
        "{admin}::delayed_action::{name}<{original}::package_admin::UpgradeKey, {original}::package_admin::UpgradeAction>",
    ));
    let proposal = ActionScheduled {
        owner: custody,
        key: false,
        change: Change::Action(UpgradeAction::Upgrade(digest.to_vec())),
        delay_ms: ADMIN_DELAY_MS,
        ready_at_ms: scheduled_at_ms + ADMIN_DELAY_MS,
    };
    assert_eq!(scheduled.events.len(), 1);
    assert_eq!(TypeTag::Struct(Box::new(scheduled.events[0].type_.clone())), upgrade_event("ActionScheduled")?);
    assert_eq!(scheduled.delayed::<ActionScheduled<UpgradeAction>>("ActionScheduled", "package_admin", "UpgradeKey")?,
        [proposal.clone()]);

    w.change_role("CancelAdmin", true)?;
    let mut cancel = ProgrammableTransactionBuilder::new();
    let witness = w.sign_in(&mut cancel, "CancelAdmin")?;
    let custody_arg = cancel.obj(w.h.shared(custody, true))?;
    let version = cancel.obj(w.h.shared(w.version, false))?;
    call(&mut cancel, original, "package_admin", "cancel_upgrade_action", vec![], vec![custody_arg, version, witness]);
    let cancelled = w.h.execute(cancel.finish())?;
    cancelled.assert_success();
    assert_eq!(cancelled.events.len(), 1);
    assert_eq!(TypeTag::Struct(Box::new(cancelled.events[0].type_.clone())), upgrade_event("ActionCancelled")?);
    // `ActionCancelled` has `ActionScheduled`'s fields, so one mirror reads both.
    assert_eq!(cancelled.delayed::<ActionScheduled<UpgradeAction>>("ActionCancelled", "package_admin", "UpgradeKey")?,
        [proposal]);
    w.h.execute(schedule)?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, false))?;
    let cap = b.obj(w.h.owned(w.admin_cap))?;
    let witness = call(&mut b, w.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]);
    let custody_arg = b.obj(w.h.shared(custody, true))?;
    let version = b.obj(w.h.shared(w.version, true))?;
    let digest = b.pure(digest.to_vec())?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let upgrade_ticket = call(&mut b, original, "package_admin", "authorize_upgrade", vec![], vec![custody_arg, version, witness, digest, clock]);
    let receipt = b.upgrade(original, upgrade_ticket, code.dependencies, code.modules);
    call(&mut b, original, "package_admin", "commit_upgrade_and_advance", vec![], vec![custody_arg, version, witness, receipt]);
    let upgrade = b.finish();
    w.h.assert_rolled_back(
        upgrade.clone(),
        Expected::Abort { package: w.admin, module: "delayed", code: 17 },
        &[custody, w.version, w.admin_cap],
        &[w.h.sender],
    )?;
    w.h.sim.advance_clock(Duration::from_millis(172_800_000));
    // Readiness does not retain a revoked UpgradeAdmin's right to authorize code.
    w.change_role("UpgradeAdmin", false)?;
    w.h.assert_rolled_back(
        upgrade.clone(),
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 },
        &[custody, w.version, w.admin_cap, w.acl],
        &[w.h.sender],
    )?;
    w.change_role("UpgradeAdmin", true)?;
    let upgraded = w.h.execute(upgrade)?;
    upgraded.assert_success();
    w.blast = upgraded.effects.created().into_iter()
        .map(|(reference, _)| reference.0).find(|id| w.h.object(*id).is_package()).unwrap();
    let (_, _, generation): (ObjectID, u8, u64) = bcs::from_bytes(&w.h.contents(w.version))?;
    assert_eq!(generation, 2);

    // A fresh adapter links to the active dependency while preserving core type origins.
    let mut adapter = w.adapter_code.clone();
    for dependency in &mut adapter.dependencies {
        if *dependency == original { *dependency = w.blast; }
    }
    w.adapter = w.h.publish(adapter)?.0;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, false))?;
    let cap = b.obj(w.h.owned(w.admin_cap))?;
    let role = parse_sui_type_tag(&format!("{original}::blast_fun_domain::AdapterAdmin"))?;
    let witness = call(&mut b, w.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]);
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;

    let admin_clock = b.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.blast, "launch_config", "schedule_migration_witness", vec![w.adapter_type("Venue")?], vec![config, version, witness, admin_clock]);
    w.h.execute(b.finish())?.assert_success();
    blast_launchpad_ptb_tests::apply_admin_changes(&mut w.h, vec![(w.blast, "launch_config", "apply_migration_witness", vec![parse_sui_type_tag(&format!("{}::mock_adapter::Venue", w.adapter))?], w.config, w.version)])?;

    let current = w.create_launch(ticket, currency, &meme, &FeeSplit::single(DESTINATION), OPENING_ROUND_MS)?;
    for name in ["set_virtual_quote", "set_graduation_target", "set_allocation_plan", "set_lp_fee_split", "set_opening_round", "finalize", "share"] {
        let mut mixed = current.clone();
        let stale = mixed.commands.iter_mut().find_map(|command| match command {
            Command::MoveCall(call) if call.module.as_str() == "launch" && call.function.as_str() == name => Some(call),
            _ => None,
        }).unwrap();
        stale.package = original;
        // This pinned runtime rejects conflicting linkage before entering Move. Unit tests
        // separately pin the version-first abort for each creation function.
        println!("mixed-generation step: {name}");
        w.h.assert_rolled_back(mixed, Expected::Error("InvalidLinkage"), &[ticket, currency, w.version, w.config], &[w.h.sender])?;
    }
    w.h.execute(current)?.assert_success();
    Ok(())
}

#[test]
fn failed_migration_ptbs_commit_nothing_and_one_ptb_completes_atomically() -> Result<()> {
    let (mut w, a, b) = setup()?;
    let b_ready = w.h.snapshot(&[b.launch, b.currency], &[]);
    let watched = [a.launch, a.currency];
    let owners = [w.h.sender, DESTINATION.into()];

    // An adapter abort after the launch migrated rolls the whole migration back.
    let pt = w.migrate(&a, &a, true)?;
    let adapter_failure = Expected::Abort { package: w.adapter, module: "mock_adapter", code: 0 };
    w.h.assert_rolled_back(pt, adapter_failure, &watched, &owners)?;

    // VM type-rule evidence, not a launch check: launch B's currency cannot stand in for launch
    // A's because distinct one-time-witness types fail PTB type checking before any Move code runs.
    let pt = w.migrate(&a, &b, false)?;
    w.h.assert_rolled_back(
        pt,
        Expected::Error("TypeMismatch"),
        &[a.launch, a.currency, b.currency],
        &owners,
    )?;

    // VM type-rule evidence, not a launch check: a PTB cannot pass pure bytes as the adapter
    // witness that opens migration.
    let pt = {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch = builder.obj(w.h.shared(a.launch, true))?;
        let version = builder.obj(w.h.shared(w.version, false))?;
        let currency = builder.obj(w.h.shared(a.currency, true))?;
        let forged = builder.pure_bytes(vec![], true);
        let handoff = call(
            &mut builder,
            w.blast,
            "launch",
            "migrate",
            vec![a.meme.clone(), sui(), w.adapter_type("Venue")?],
            vec![launch, version, currency, forged],
        );
        let Argument::Result(handoff) = handoff else { unreachable!() };
        // Taking the Meme principal is the only other command, so a forged witness surfaces
        // as its own error rather than behind a static transfer check.
        let coin = call(
            &mut builder,
            SUI_FRAMEWORK_PACKAGE_ID,
            "coin",
            "from_balance",
            vec![a.meme.clone()],
            vec![Argument::NestedResult(handoff, 0)],
        );
        builder.transfer_args(w.h.sender, vec![coin]);
        builder.finish()
    };
    w.h.assert_rolled_back(pt, Expected::Error("InvalidUsageOfPureArg"), &watched, &owners)?;
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::MigrationReady);

    // The complete migration succeeds in one PTB, pays the creator's recipient, settles Blast's
    // Meme and Quote allocation into the launch ledger, and leaves the caller with nothing.
    let pt = w.migrate(&a, &a, false)?;
    let outcome = w.h.execute(pt)?;
    outcome.assert_success();
    assert_eq!(
        outcome.wrapped_payloads(w.blast),
        ["MigrationAllocationPaid", "ProtocolFeesAccrued", "Migrated"]
    );
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::Migrated);
    let migrated = outcome.events_of("events", "Migrated");
    assert_eq!(migrated.len(), 1);
    let migrated: Migrated = bcs::from_bytes(migrated[0])?;
    assert_eq!(migrated.launch_id, a.launch);
    assert!(migrated.meme > 0 && migrated.quote > 0);
    let vaults = outcome.created(&w.h, "mock_adapter", "MockVault");
    assert_eq!(vaults.len(), 1);
    assert!(w.h.object(vaults[0]).is_shared());
    let paid = outcome.events_of("events", "MigrationAllocationPaid");
    assert_eq!(paid.len(), 1);
    let paid: MigrationAllocationPaid = bcs::from_bytes(paid[0])?;
    assert_eq!((paid.launch_id, paid.destination), (a.launch, DESTINATION.into()));
    assert!(paid.meme > 0 && paid.quote > 0);
    assert_eq!(outcome.coins_created_for(&w.h, DESTINATION.into()), w.coins(&a, paid.meme, paid.quote));
    let accrued = outcome.events_of("events", "ProtocolFeesAccrued");
    assert_eq!(accrued.len(), 1);
    let accrued: ProtocolFeesAccrued = bcs::from_bytes(accrued[0])?;
    assert_eq!(accrued.launch_id, a.launch);
    assert!(accrued.meme_amount > 0 && accrued.quote_amount > 0);
    assert!(
        outcome
            .effects
            .created()
            .iter()
            .all(|(_, owner)| *owner != Owner::AddressOwner(w.h.sender)),
        "the caller received an object"
    );

    // A migrated launch cannot migrate again, and launch B was never touched.
    let pt = w.migrate(&a, &a, false)?;
    let lifecycle = Expected::Abort { package: w.blast, module: "launch", code: INVALID_LAUNCH_LIFECYCLE };
    w.h.assert_rolled_back(pt, lifecycle, &watched, &owners)?;
    assert_eq!(w.h.snapshot(&[b.launch, b.currency], &[]), b_ready);

    Ok(())
}

#[test]
fn zero_sum_and_seventeen_recipient_fee_splits_abort_before_the_launch_exists() -> Result<()> {
    let mut w = world("fee_split_boundaries")?;
    let sixteen = FeeSplit::sixteen(0xA0, 10);
    // An empty split fails the 10,000 sum (`invalid_shares`); a seventeenth distinct recipient
    // fails capacity (`recipient_capacity_reached`) while the sum stays whole.
    let rejected =
        [(FeeSplit::default(), INVALID_SHARES), (sixteen.clone().with_seventeenth(), RECIPIENT_CAPACITY_REACHED)];
    let blast = w.blast;
    let abort = |code| Expected::Abort { package: blast, module: "allocation", code };
    let owners = [w.h.sender, DESTINATION.into()];

    // Each rejected split aborts before the ticket is consumed; the same ticket then opens with
    // sixteen recipients, which the launch records unchanged.
    let (ticket, currency, meme) = w.publish_ticket()?;
    for (fee_split, code) in &rejected {
        let pt = w.create_launch(ticket, currency, &meme, fee_split, NO_OPENING_ROUND)?;
        w.h.assert_rolled_back(pt, abort(*code), &[ticket, currency], &owners)?;
    }
    let (_, created) = w.open_split_launch(ticket, currency, meme, &sixteen)?;
    assert_eq!(w.launch_created(&created)?.lp_fee_split, sixteen);

    Ok(())
}

#[test]
fn maximum_fee_split_fits_protocol_limits_at_creation_and_migration() -> Result<()> {
    let mut w = world("fee_split_capacity")?;
    let fee_split = FeeSplit::sixteen(0xA0, 10);
    let mut records = Vec::new();

    let (ticket, currency, meme) = w.publish_ticket()?;
    let (a, created) = w.open_split_launch(ticket, currency, meme, &fee_split)?;
    let launch_created = w.launch_created(&created)?;
    assert_eq!(launch_created.lp_fee_split, fee_split);
    assert_eq!(launch_created.opening_round_ms, NO_OPENING_ROUND);
    assert_eq!(
        (launch_created.pool_tick_spacing, launch_created.pool_fee_rate),
        (POOL_TICK_SPACING, POOL_FEE_RATE),
    );
    assert_eq!(
        (
            launch_created.allocation_plan.protocol_meme_bps,
            launch_created.allocation_plan.protocol_quote_bps,
        ),
        (BLAST_BPS, BLAST_BPS),
    );
    assert_eq!(launch_created.allocation_plan.recipients, [(DESTINATION.into(), 500, 500)]);
    records.push(w.record(&a, "create_launch", "3 parts + 16 recipients", &created));

    // The launch carries the split unchanged to migration, which neither reads nor pays it.
    w.buy_to_migration(&a)?;
    let migrated = w.h.execute(w.migrate(&a, &a, false)?)?;
    migrated.assert_success();
    assert_eq!(
        migrated.wrapped_payloads(w.blast),
        ["MigrationAllocationPaid", "ProtocolFeesAccrued", "Migrated"]
    );
    records.push(w.record(&a, "migrate", "3 parts + 16 recipients", &migrated));

    println!(
        "LAUNCH_FEE_SPLIT_CAPACITY {}",
        json!({ "limits": w.h.protocol_limits(), "fixture": { "fee_split": fee_split }, "records": records })
    );

    Ok(())
}

#[test]
fn opening_round_keeps_one_record_per_bidder_and_nothing_trades_before_settlement() -> Result<()> {
    let mut w = world("opening_round")?;
    let launch = w.open_launch(OPENING_ROUND_MS)?;
    let owners = [w.h.sender];
    let blast = w.blast;
    let abort = |code| Expected::Abort { package: blast, module: "launch", code };

    // The first bid creates the bidder's launch-owned record; a later bid only raises it.
    let first = w.h.execute(w.join(&launch, BID)?)?;
    first.assert_success();
    assert_eq!(first.wrapped_payloads(w.blast), ["OpeningRoundJoined"]);
    let records = first.created(&w.h, "dynamic_field", "Field");
    assert_eq!(records.len(), 1, "the first bid creates one bidder record");
    let record = records[0];
    assert_eq!(*w.h.object(record).owner(), Owner::ObjectOwner(launch.launch.into()));
    let later = w.h.execute(w.join(&launch, BID)?)?;
    later.assert_success();
    assert!(later.created(&w.h, "dynamic_field", "Field").is_empty());
    assert!(later.effects.mutated().iter().any(|(object, _)| object.0 == record));
    let bid: OpeningRoundBid = bcs::from_bytes(&w.h.contents(record))?;
    assert_eq!((bid.bidder, bid.bid), (w.h.sender, 2 * BID));

    // Before the end nothing trades or pays out, settling is early, and a zero bid is refused;
    // each failure leaves the launch, the record, and the bidder's coins exactly as they were.
    let watched = [launch.launch, record];
    let bidder = w.h.sender;
    for (pt, code) in [
        (w.buy(&launch, BID, 1)?, INVALID_LAUNCH_LIFECYCLE),
        (w.deliver(&launch, bidder)?, INVALID_LAUNCH_LIFECYCLE),
        (w.settle(&launch)?, OPENING_ROUND_NOT_ENDED),
        (w.join(&launch, 0)?, ZERO_OPENING_ROUND_BID),
    ] {
        w.h.assert_rolled_back(pt, abort(code), &watched, &owners)?;
    }

    // At the end bidding closes, and settlement buys once with the whole pot.
    w.h.sim.advance_clock(Duration::from_millis(OPENING_ROUND_MS));
    let pt = w.join(&launch, BID)?;
    w.h.assert_rolled_back(pt, abort(OPENING_ROUND_ENDED), &watched, &owners)?;
    let settled = w.h.execute(w.settle(&launch)?)?;
    settled.assert_success();
    assert_eq!(settled.wrapped_payloads(w.blast), ["Bought", "OpeningRoundSettled"]);
    let bought: Bought = bcs::from_bytes(settled.events_of("events", "Bought")[0])?;
    let round: OpeningRoundSettled = bcs::from_bytes(settled.events_of("events", "OpeningRoundSettled")[0])?;
    assert_eq!((bought.quote_in, bought.quote_refund), (2 * BID, 0));
    assert_eq!((round.launch_id, round.bids, round.meme, round.quote), (launch.launch, 2 * BID, bought.meme_out_net, 0));
    assert_eq!(w.launch_lifecycle(&launch)?, LaunchLifecycle::Live);

    // Delivery retires the record and sends the lone bidder everything the pot bought; then the
    // curve trades.
    let delivered = w.h.execute(w.deliver(&launch, bidder)?)?;
    delivered.assert_success();
    assert_eq!(delivered.wrapped_payloads(w.blast), ["OpeningRoundDelivered"]);
    assert!(delivered.effects.deleted().iter().any(|(object, _, _)| *object == record));
    assert_eq!(delivered.coins_created_for(&w.h, bidder), w.coins(&launch, round.meme, 0));
    let open = w.h.execute(w.buy(&launch, BID, 1)?)?;
    open.assert_success();
    assert_eq!(open.wrapped_payloads(w.blast), ["Bought"]);

    // Capacity evidence: net storage charged by each step. Only the first bid leaves a new object
    // behind, and delivery refunds it.
    let net_storage = |name: &str, outcome: &Outcome| {
        let cost = outcome.effects.gas_cost_summary();
        println!(
            "{name}: storage_cost {} storage_rebate {} non_refundable {} net {}",
            cost.storage_cost,
            cost.storage_rebate,
            cost.non_refundable_storage_fee,
            cost.storage_cost as i64 - cost.storage_rebate as i64,
        );
        cost.storage_cost as i64 - cost.storage_rebate as i64
    };
    let first_net = net_storage("first bid", &first);
    let later_net = net_storage("later bid", &later);
    net_storage("settlement", &settled);
    let delivery_net = net_storage("delivery", &delivered);
    net_storage("buy after settlement", &open);
    assert!(first_net > later_net);
    assert!(delivery_net < first_net);

    Ok(())
}

/// Mirrors `blast_fun::events::Bought` field order for BCS decoding.
#[derive(Deserialize)]
struct Bought {
    _launch_id: ObjectID,
    quote_in: u64,
    _meme_out_gross: u64,
    meme_out_net: u64,
    quote_refund: u64,
    _protocol_meme_fee: u64,
    _creator_meme_fee: u64,
    _protocol_quote_fee: u64,
    _creator_quote_fee: u64,
    _meme_reserve: u64,
    _real_quote_reserve: u64,
}

/// Mirrors `blast_fun::events::OpeningRoundSettled`.
#[derive(Deserialize)]
struct OpeningRoundSettled {
    launch_id: ObjectID,
    bids: u64,
    meme: u64,
    quote: u64,
}

/// Mirrors `0x2::dynamic_field::Field<blast_fun::launch::OpeningRoundBidKey, u64>`.
#[derive(Deserialize)]
struct OpeningRoundBid {
    _id: ObjectID,
    bidder: SuiAddress,
    bid: u64,
}

/// Mirrors `blast_fun::events::LaunchCreated`.
#[derive(Deserialize)]
struct LaunchCreated {
    _launch_id: ObjectID,
    _ticket_id: ObjectID,
    _quote: String,
    _migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: FeeSplit,
    _virtual_quote: u64,
    _graduation_target: u64,
    _quote_fee_bps: u64,
    _meme_fee_bps: u64,
    allocation_plan: AllocationPlan,
    opening_round_ms: u64,
    _creation_fee: u64,
    _partner_id: Option<ObjectID>,
}

/// Mirrors `blast_fun::allocation::AllocationPlan`; each recipient is (destination, Meme, Quote).
#[derive(Deserialize)]
struct AllocationPlan {
    _curve_meme_bps: u64,
    _lp_meme_bps: u64,
    _lp_quote_bps: u64,
    protocol_meme_bps: u64,
    protocol_quote_bps: u64,
    recipients: Vec<(SuiAddress, u64, u64)>,
}

/// Mirrors `blast_fun::events::Migrated` field order for BCS decoding.
#[derive(Deserialize)]
struct Migrated {
    launch_id: ObjectID,
    meme: u64,
    quote: u64,
    _disposed_meme: u64,
    _total_supply_after: u64,
}

/// `blast_fun::launch::Launch` begins with its UID and this fieldless enum, whose BCS tag is one
/// byte; the rest of the launch is not mirrored.
#[derive(Debug, Deserialize, PartialEq)]
enum LaunchLifecycle {
    OpeningRound,
    Live,
    MigrationReady,
    Migrated,
}

/// Mirrors `blast_fun::allocation::FeeSplit`; each `Bps` is one `u64` in BCS.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct FeeSplit {
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    burn_bps: u64,
    recipients: Vec<Route>,
}

impl FeeSplit {
    /// Every collection wholly to one recipient.
    fn single(destination: ObjectID) -> Self {
        let recipients = vec![Route { destination: destination.into(), bps: 10_000 }];
        Self { recipients, ..Self::default() }
    }

    /// Every part set, and sixteen recipients whose weights fall by `step`, so they are distinct;
    /// the whole split sums to 10,000.
    fn sixteen(tag: u8, step: u64) -> Self {
        let (creator_bps, auto_lp_bps, rewards_bps, burn_bps) = (1_000, 600, 400, 400);
        let shared = 10_000 - creator_bps - auto_lp_bps - rewards_bps - burn_bps;
        assert_eq!((shared - 120 * step) % 16, 0);
        let lowest = (shared - 120 * step) / 16;
        let recipients = (0..16u8)
            .map(|i| Route { destination: address(&[tag, i]).into(), bps: lowest + step * u64::from(15 - i) })
            .collect();

        Self { creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients }
    }

    /// Moves the rewards share to a seventeenth distinct recipient; the sum stays whole.
    fn with_seventeenth(mut self) -> Self {
        let bps = std::mem::take(&mut self.rewards_bps);
        self.recipients.push(Route { destination: address(&[0x17, 0x17]).into(), bps });
        self
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct Route {
    destination: SuiAddress,
    bps: u64,
}

/// Mirrors `blast_fun::events::MigrationAllocationPaid`.
#[derive(Deserialize)]
struct MigrationAllocationPaid {
    launch_id: ObjectID,
    destination: SuiAddress,
    meme: u64,
    quote: u64,
}

/// Mirrors `blast_fun::events::ProtocolFeesAccrued`.
#[derive(Deserialize)]
struct ProtocolFeesAccrued {
    launch_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}

/// Two launches without an opening round at MigrationReady.
fn setup() -> Result<(World, Launch, Launch)> {
    let mut w = world("atomic_migration")?;
    let mut launches = Vec::new();
    for _ in 0..2 {
        let launch = w.open_launch(NO_OPENING_ROUND)?;
        w.buy_to_migration(&launch)?;
        launches.push(launch);
    }
    let b = launches.pop().expect("launch B");
    let a = launches.pop().expect("launch A");
    assert_ne!(a.meme, b.meme);

    Ok((w, a, b))
}

/// Publishes the packages and admits SUI and the adapter under the production admin path. Each
/// test passes its own `work` directory for build configuration.
fn world(work: &str) -> Result<World> {
    let sui_dir = sui_dir();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture");
    let work = blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join(work);
    let mut h = Harness::new()?;

    let timelock_dir = timelock_dir()?;
    let admin_dir = sui_dir.join("admin");
    let launchpad_dir = sui_dir.join("launchpad");
    let (timelock, _) = h.publish(build_timelock(&work)?)?;
    let (admin, admin_published) = h.publish(build(&admin_dir, &[], &work)?)?;
    let partners_dir = sui_dir.join("partners");
    let (partners, _) = h.publish(build(&partners_dir, &[(&timelock_dir, timelock), (&admin_dir, admin)], &work)?)?;
    let core = [(timelock_dir.as_path(), timelock), (admin_dir.as_path(), admin), (partners_dir.as_path(), partners)];
    let core_code = build(&launchpad_dir, &core, &work)?;
    let (blast, published) = h.publish(core_code.clone())?;
    let one = |outcome: &Outcome, module: &str, name: &str| {
        let ids = outcome.created(&h, module, name);
        assert_eq!(ids.len(), 1, "{module}::{name}");
        ids[0]
    };
    let acl = one(&admin_published, "blast_acl", "ACL");
    let root = one(&admin_published, "blast_acl", "SuperAdminCap");
    let config = one(&published, "launch_config", "LaunchConfig");
    let runtime = one(&published, "runtime_config", "RuntimeConfig");
    let linked = [core[0], core[1], core[2], (launchpad_dir.as_path(), blast)];
    let adapter_code = build(&fixture.join("adapter"), &linked, &work)?;
    let (adapter, _) = h.publish(adapter_code.clone())?;
    let (version, custody) = h.wrap_launchpad(blast, &published, admin, &admin_published, sui(), parse_sui_type_tag(&format!("{adapter}::mock_adapter::Venue"))?)?;
    let project = build(&fixture.join("project"), &linked, &work)?;
    let mut w = World { h, blast, adapter, version, runtime, config, project, core_code, adapter_code, admin, acl, root, admin_cap: ObjectID::ZERO, custody };

    w.h.unpause(blast, "blast_fun", admin, &admin_published, version, 7)?;

    // Production admin path: the configured root owner's SuperAdminCap grants one AdminCap and each role the
    // setters below take; the cap then signs in once per role.
    let mut roles = Vec::new();
    for role in ["ListingAdmin", "AdapterAdmin", "FeeAdmin", "TreasuryAdmin"] {
        roles.push(parse_sui_type_tag(&format!("{blast}::blast_fun_domain::{role}"))?);
    }
    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, true))?;
    let root_arg = builder.obj(w.h.owned(root))?;
    let recipient = builder.pure(w.h.sender)?;
    call(&mut builder, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
    let granted = w.h.impersonate_cap_owner(root, builder.finish())?;
    granted.assert_success();
    let admin_cap = granted.created(&w.h, "blast_acl", "AdminCap")[0];
    w.admin_cap = admin_cap;

    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, true))?;
    let root_arg = builder.obj(w.h.owned(root))?;
    let admin_cap_id = builder.pure(admin_cap)?;
    for role in &roles {
        call(&mut builder, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, admin_cap_id]);
    }
    w.h.impersonate_cap_owner(root, builder.finish())?.assert_success();

    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, false))?;
    let admin_cap = builder.obj(w.h.owned(admin_cap))?;
    let mut witnesses = Vec::new();
    for role in roles {
        witnesses.push(call(&mut builder, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, admin_cap]));
    }
    let [_listing_admin, _adapter_admin, fee_admin, treasury_admin]: [Argument; 4] =
        witnesses.try_into().expect("one witness per role");
    let config_arg = builder.obj(w.h.shared(config, true))?;
    let version_arg = builder.obj(w.h.shared(version, false))?;
    let hundred = builder.pure(100u64)?;
    let fee = call(&mut builder, blast, "bps", "new", vec![], vec![hundred]);
    let admin_clock = builder.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = builder.pure(172_800_000u64)?;
    call(&mut builder, blast, "launch_config", "schedule_trade_fees", vec![], vec![config_arg,
        version_arg,
        fee_admin,
        fee,
        fee, next_delay, admin_clock]);
    let blast_bps = w.bps(&mut builder, BLAST_BPS)?;
    let admin_clock = builder.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = builder.pure(172_800_000u64)?;
    call(&mut builder, blast, "launch_config", "schedule_protocol_allocation", vec![], vec![config_arg,
        version_arg,
        treasury_admin,
        blast_bps,
        blast_bps, next_delay, admin_clock]);
    w.h.execute(builder.finish())?.assert_success();
    blast_launchpad_ptb_tests::apply_admin_changes(&mut w.h, vec![
        (blast, "launch_config", "apply_trade_fees", vec![], config, version),
        (blast, "launch_config", "apply_protocol_allocation", vec![], config, version),
    ])?;

    Ok(w)
}

impl World {
    fn sign_in(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let cap = b.obj(self.h.owned(self.admin_cap))?;
        let role = parse_sui_type_tag(&format!("{}::blast_fun_domain::{role}", self.blast))?;
        Ok(call(b, self.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]))
    }

    fn change_role(&mut self, role: &str, grant: bool) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = b.obj(self.h.shared(self.acl, true))?;
        let root = b.obj(self.h.owned(self.root))?;
        let cap = b.pure(self.admin_cap)?;
        let role = parse_sui_type_tag(&format!("{}::blast_fun_domain::{role}", self.blast))?;
        call(&mut b, self.admin, "blast_acl", if grant { "grant_role" } else { "revoke_role" }, vec![role], vec![acl, root, cap]);
        self.h.impersonate_cap_owner(self.root, b.finish())?.assert_success();
        Ok(())
    }

    fn schedule_treasury(&self, destination: SuiAddress) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in(&mut b, "TreasuryAdmin")?;
        let config = b.obj(self.h.shared(self.runtime, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let destination = b.pure(destination)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let next_delay = b.pure(172_800_000u64)?;
        call(&mut b, self.blast, "runtime_config", "schedule_treasury", vec![], vec![config, version, witness, destination, next_delay, clock]);
        Ok(b.finish())
    }

    fn append_cap_recipient(
        &self,
        b: &mut ProgrammableTransactionBuilder,
        launch: &Launch,
        cap: &str,
        role: &str,
        recipient: SuiAddress,
    ) -> Result<()> {
        let witness = self.sign_in(b, role)?;
        let launch_arg = b.obj(self.h.shared(launch.launch, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let recipient = b.pure(recipient)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(b, self.blast, "launch", &format!("schedule_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, witness, recipient, clock]);
        Ok(())
    }

    fn apply_setting(&self, module: &str, function: &str, object: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(self.h.shared(object, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.blast, module, function, vec![], vec![config, version, clock]);
        Ok(b.finish())
    }

    fn applied_treasury(&self) -> Result<SuiAddress> {
        let (_, _, _, treasury): (ObjectID, Vec<u8>, Delayed<u64>, Delayed<SuiAddress>) = bcs::from_bytes(&self.h.contents(self.runtime))?;
        assert_eq!(treasury.owner, self.runtime);
        Ok(treasury.value)
    }

    fn set_pause(&mut self, pause: bool, bits: u8) -> Result<()> {
        self.h.execute(self.pause_command(pause, bits)?)?.assert_success();
        Ok(())
    }

    fn pause_command(&self, pause: bool, bits: u8) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        self.append_pause(&mut b, pause, bits, if pause { "PauseAdmin" } else { "UnpauseAdmin" })?;
        Ok(b.finish())
    }

    fn append_pause(&self, b: &mut ProgrammableTransactionBuilder, pause: bool, bits: u8, role: &str) -> Result<()> {
        let witness = self.sign_in(b, role)?;
        let version = b.obj(self.h.shared(self.version, true))?;
        let bits = b.pure(bits)?;
        call(b, self.blast, "blast_fun", if pause { "pause" } else { "unpause" }, vec![], vec![version, witness, bits]);
        Ok(())
    }

    fn pause_state(&self) -> Result<(ObjectID, u8, u64)> {
        Ok(bcs::from_bytes(&self.h.contents(self.version))?)
    }

    fn replace_pause_mask(&mut self, mask: u8) -> Result<()> {
        let (_, current, _) = self.pause_state()?;
        if current != 0 {
            self.set_pause(false, current)?;
        }
        if mask != 0 {
            self.set_pause(true, mask)?;
        }
        Ok(())
    }

    /// Only seed the stored generation; masks are always reached through real public calls.
    fn set_pause_generation_for_fixture(&mut self, generation: u64) -> Result<()> {
        let (id, paused, _) = self.pause_state()?;
        let mut object = self.h.object(self.version);
        object.data.try_as_move_mut().expect("PackageVersion")
            .set_contents_unsafe(bcs::to_bytes(&(id, paused, generation))?);
        self.h.insert(object);
        Ok(())
    }

    /// Publishes one generated project and opens its SUI-quoted launch with `opening_round_ms`,
    /// with the LP-fee split paying `DESTINATION` wholly.
    fn open_launch(&mut self, opening_round_ms: u64) -> Result<Launch> {
        let (ticket, currency, meme) = self.publish_ticket()?;
        let pt = self.create_launch(ticket, currency, &meme, &FeeSplit::single(DESTINATION), opening_round_ms)?;
        let created = self.h.execute(pt)?;

        Ok(self.created_launch(&created, meme, currency))
    }

    /// Opens `ticket`'s launch without an opening round with `fee_split` and returns it with the
    /// creation outcome.
    fn open_split_launch(
        &mut self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: TypeTag,
        fee_split: &FeeSplit,
    ) -> Result<(Launch, Outcome)> {
        let created = self.h.execute(self.create_launch(ticket, currency, &meme, fee_split, NO_OPENING_ROUND)?)?;

        Ok((self.created_launch(&created, meme, currency), created))
    }

    /// One PTB that starts `ticket`'s launch through the adapter, sets the graduation target, the
    /// allocation plan, `fee_split`, and any opening round, then finalizes and shares it.
    fn create_launch(
        &self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        fee_split: &FeeSplit,
        opening_round_ms: u64,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let fee_split = self.fee_split_arg(&mut builder, fee_split)?;
        let plan = self.plan_arg(&mut builder)?;
        let ticket = builder.obj(self.h.owned(ticket))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let tick_spacing = builder.pure(POOL_TICK_SPACING)?;
        let fee_rate = builder.pure(POOL_FEE_RATE)?;
        let initializer = call(&mut builder, self.adapter, "mock_adapter", "new", vec![meme.clone()], vec![
            ticket,
            version,
            config,
            tick_spacing,
            fee_rate,
        ]);
        let pair = vec![meme.clone(), sui()];
        let virtual_quote = builder.pure(5_000_000u64)?;
        call(&mut builder, self.blast, "launch", "set_virtual_quote", pair.clone(), vec![initializer, version, virtual_quote]);
        let target = builder.pure(TARGET)?;
        call(&mut builder, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, version, target]);
        call(&mut builder, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, version, plan]);
        call(&mut builder, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, version, fee_split]);
        if opening_round_ms != NO_OPENING_ROUND {
            let opening_round_ms = builder.pure(opening_round_ms)?;
            call(&mut builder, self.blast, "launch", "set_opening_round", pair.clone(), vec![
                initializer, version,
                opening_round_ms,
            ]);
        }
        let currency = builder.obj(self.h.shared(currency, true))?;
        let creation_fee = call(&mut builder, SUI_FRAMEWORK_PACKAGE_ID, "coin", "zero", vec![sui()], vec![]);
        let launch = call(&mut builder, self.blast, "launch", "finalize", pair.clone(), vec![
            initializer, version,
            currency,
            config,
            creation_fee,
        ]);
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(builder.finish())
    }

    /// Publishes one generated project, which runs its OTW init: the ticket goes to the publisher
    /// and the Currency to the registry, which must finalize it into its shared form. Returns the
    /// ticket, the shared currency, and the Meme type.
    fn publish_ticket(&mut self) -> Result<(ObjectID, ObjectID, TypeTag)> {
        let (project_id, published) = self.h.publish(self.project.clone())?;
        assert_eq!(published.wrapped_payloads(self.blast), ["LaunchTicketCreated"]);
        let ticket = published.created(&self.h, "launch_ticket", "LaunchTicket")[0];
        let pending_currency = published.created(&self.h, "coin_registry", "Currency")[0];
        let meme = parse_sui_type_tag(&format!("{project_id}::token::TOKEN"))?;

        let mut builder = ProgrammableTransactionBuilder::new();
        let registry = builder.obj(self.h.shared(SUI_COIN_REGISTRY_OBJECT_ID, true))?;
        let receiving = builder.obj(ObjectArg::Receiving(
            self.h.object(pending_currency).compute_object_reference(),
        ))?;
        call(&mut builder, SUI_FRAMEWORK_PACKAGE_ID, "coin_registry", "finalize_registration", vec![
            meme.clone(),
        ], vec![registry, receiving]);
        let finalized = self.h.execute(builder.finish())?;
        finalized.assert_success();
        let currency = finalized.created(&self.h, "coin_registry", "Currency")[0];

        Ok((ticket, currency, meme))
    }

    /// The launch a successful creation shared.
    fn created_launch(&self, created: &Outcome, meme: TypeTag, currency: ObjectID) -> Launch {
        created.assert_success();
        assert_eq!(
            created.wrapped_payloads(self.blast),
            ["LaunchCreated", "LaunchShared"],
        );
        let launch = created.created(&self.h, "launch", "Launch");
        assert_eq!(launch.len(), 1, "launch::Launch");
        assert!(self.h.object(launch[0]).is_shared());

        Launch { meme, launch: launch[0], currency }
    }

    /// Decodes the one `LaunchCreated` of a creation.
    fn launch_created(&self, created: &Outcome) -> Result<LaunchCreated> {
        let launch_created = created.events_of("events", "LaunchCreated");
        assert_eq!(launch_created.len(), 1);

        Ok(bcs::from_bytes(launch_created[0])?)
    }

    fn adapter_type(&self, name: &str) -> Result<TypeTag> {
        parse_sui_type_tag(&format!("{}::mock_adapter::{name}", self.adapter))
    }

    fn buy_to_migration(&mut self, launch: &Launch) -> Result<()> {
        let pt = self.buy(launch, BUY, 1)?;
        let bought = self.h.execute(pt)?;
        bought.assert_success();
        assert_eq!(bought.wrapped_payloads(self.blast), ["Bought"]);
        assert_eq!(self.launch_lifecycle(launch)?, LaunchLifecycle::MigrationReady);

        Ok(())
    }

    /// Buys from `launch` with `quote_in` MIST split from gas and keeps both returned coins.
    fn buy(&self, launch: &Launch, quote_in: u64, min_meme_out: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let min_out = builder.pure(min_meme_out)?;
        let Argument::Result(bought) = call(
            &mut builder,
            self.blast,
            "launch",
            "buy",
            vec![launch.meme.clone(), sui()],
            vec![launch_arg, version, runtime, Argument::NestedResult(split, 0), min_out],
        ) else {
            unreachable!()
        };
        builder.transfer_args(self.h.sender, vec![
            Argument::NestedResult(bought, 0),
            Argument::NestedResult(bought, 1),
        ]);

        Ok(builder.finish())
    }

    /// Joins `launch`'s opening round with `quote_in` MIST split from gas.
    fn join(&self, launch: &Launch, quote_in: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "join_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            Argument::NestedResult(split, 0),
            clock,
        ]);

        Ok(builder.finish())
    }

    /// Settles `launch`'s opening round.
    fn settle(&self, launch: &Launch) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "settle_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            runtime,
            clock,
        ]);

        Ok(builder.finish())
    }

    /// Delivers `bidder`'s share of `launch`'s settled opening round.
    fn deliver(&self, launch: &Launch, bidder: SuiAddress) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let bidder = builder.pure(bidder)?;
        call(&mut builder, self.blast, "launch", "deliver_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            bidder,
        ]);

        Ok(builder.finish())
    }

    /// The coins one payment of `meme` and `quote` on `launch` creates, in `coins_created_for` order.
    fn coins(&self, launch: &Launch, meme: u64, quote: u64) -> Vec<(String, u64)> {
        let mut coins = vec![
            (launch.meme.to_canonical_string(true), meme),
            (sui().to_canonical_string(true), quote),
        ];
        coins.retain(|(_, value)| *value > 0);
        coins.sort();
        coins
    }

    fn launch_lifecycle(&self, launch: &Launch) -> Result<LaunchLifecycle> {
        let contents = self.h.contents(launch.launch);
        let (_, lifecycle): (ObjectID, LaunchLifecycle) = bcs::from_bytes(&contents[..33])?;

        Ok(lifecycle)
    }

    /// The adapter entry point with `launch`'s launch and `currency_owner`'s currency.
    fn migrate(&self, launch: &Launch, currency_owner: &Launch, fail: bool) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let currency = builder.obj(self.h.shared(currency_owner.currency, true))?;
        let fail = builder.pure(fail)?;
        call(&mut builder, self.adapter, "mock_adapter", "migrate", vec![launch.meme.clone()], vec![
            launch_arg,
            version,
            currency,
            fail,
        ]);

        Ok(builder.finish())
    }
}

/// Launch fixtures and measurements.
impl World {
    fn bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure(value)?;

        Ok(call(builder, self.blast, "bps", "new", vec![], vec![value]))
    }

    /// The fixture plan: 70% of the Meme on the curve, 20% of the Meme and 90% of the Quote to
    /// the pool, and 5% of each to `DESTINATION`; finalization records Blast's 5% of each as the
    /// explicit protocol allocation.
    fn plan_arg(&self, builder: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        let destination = builder.pure(SuiAddress::from(DESTINATION))?;
        let share = self.bps(builder, 500)?;
        let recipient = call(builder, self.blast, "allocation", "recipient", vec![], vec![destination, share, share]);
        let recipient_type = parse_sui_type_tag(&format!("{}::allocation::Recipient", self.blast))?;
        let recipients = builder.command(Command::make_move_vec(Some(recipient_type), vec![recipient]));
        let curve_meme = self.bps(builder, 7_000)?;
        let lp_meme = self.bps(builder, 2_000)?;
        let lp_quote = self.bps(builder, 9_000)?;

        Ok(call(builder, self.blast, "allocation", "plan", vec![], vec![curve_meme, lp_meme, lp_quote, recipients]))
    }

    /// Builds `fee_split` through the public constructors, as a client would, with every value its
    /// own pure input.
    fn fee_split_arg(&self, builder: &mut ProgrammableTransactionBuilder, fee_split: &FeeSplit) -> Result<Argument> {
        let mut recipients = Vec::new();
        for route in &fee_split.recipients {
            let bps = self.unique_bps(builder, route.bps)?;
            let destination = builder.pure_bytes(bcs::to_bytes(&route.destination)?, true);
            recipients.push(call(builder, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let route = parse_sui_type_tag(&format!("{}::allocation::Route", self.blast))?;
        let recipients = builder.command(Command::make_move_vec(Some(route), recipients));
        let creator_bps = self.unique_bps(builder, fee_split.creator_bps)?;
        let auto_lp_bps = self.unique_bps(builder, fee_split.auto_lp_bps)?;
        let rewards_bps = self.unique_bps(builder, fee_split.rewards_bps)?;
        let burn_bps = self.unique_bps(builder, fee_split.burn_bps)?;

        Ok(call(builder, self.blast, "allocation", "fee_split", vec![], vec![
            creator_bps,
            auto_lp_bps,
            rewards_bps,
            burn_bps,
            recipients,
        ]))
    }

    /// A `Bps` from its own pure input, never shared with an equal value.
    fn unique_bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure_bytes(bcs::to_bytes(&value)?, true);

        Ok(call(builder, self.blast, "bps", "new", vec![], vec![value]))
    }

    /// One measurement: the operation and fixture, the launch object's size afterwards, and the
    /// transaction's resources against the protocol limits.
    fn record(&self, launch: &Launch, operation: &str, fixture: &str, outcome: &Outcome) -> Value {
        json!({
            "operation": operation,
            "fixture": fixture,
            "launch_object": {
                "contents_bytes": self.h.contents(launch.launch).len(),
                "metered_bytes": self.h.object(launch.launch).object_size_for_gas_metering(),
            },
            "resources": self.h.resources(outcome),
        })
    }
}

fn sui() -> TypeTag {
    parse_sui_type_tag("0x2::sui::SUI").expect("SUI type")
}
