//! Publication must remain inactive until the original, never-upgraded cap enters custody.

use anyhow::Result;
use blast_launchpad_ptb_tests::{
    Delayed, DelayedApplied, DelayedScheduled, Expected, Harness, Outcome, Proposal, build, call, sui_dir,
};
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    move_package::{MovePackage, UpgradeCap},
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command},
};

#[test]
fn only_fresh_matching_custody_enables_the_launchpad() -> Result<()> {
    let work = blast_launchpad_ptb_tests::test_work_dir().join("launchpad_bootstrap");
    let sui = sui_dir();
    let admin_dir = sui.join("admin");
    let partners_dir = sui.join("partners");
    let mut h = Harness::new()?;
    let (admin, admin_publication) = h.publish(build(&admin_dir, &[], &work)?)?;
    let (partners, _) = h.publish(build(&partners_dir, &[(&admin_dir, admin)], &work)?)?;
    assert_initial_partner_payment(&mut h, admin, &admin_publication, partners)?;
    let code = build(&sui.join("launchpad"), &[(&admin_dir, admin), (&partners_dir, partners)], &work)?;
    let (blast, publication) = h.publish(code.clone())?;
    assert!(publication.created(&h, "blast_fun", "PackageVersion").is_empty());
    assert!(publication.created(&h, "package_admin", "PackageAdmin").is_empty());
    assert!(publication.created(&h, "package", "Publisher").is_empty());
    let bootstrap = publication.created(&h, "blast_fun", "Publication")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 1);
    let config = publication.created(&h, "launch_config", "LaunchConfig")[0];
    let foreign_cap = admin_publication.created(&h, "package", "UpgradeCap")[0];

    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(foreign_cap))?;
    call(&mut b, blast, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 12 },
        &[bootstrap, cap, foreign_cap, config],
        &[h.sender],
    )?;

    // Initial routes use real ACL roles at zero delay; enabling 48h needs no Clock advance.
    let clock_before = h.contents(sui_types::SUI_CLOCK_OBJECT_ID);
    let (version, _) = h.wrap_launchpad(blast, &publication, admin, &admin_publication, parse_sui_type_tag("0x2::sui::SUI")?, parse_sui_type_tag(&format!("{blast}::blast_fun::BLAST_FUN"))?)?;
    h.unpause(blast, "blast_fun", admin, &admin_publication, version, 7)?;
    h.shared(version, false);
    assert_eq!(h.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
    // Simulacrum resolves historical owned inputs; test_scenario covers repeated intake.
    assert!(h.sim.store().get_object(&bootstrap).is_none());

    assert_delay_changes_use_the_old_notice(&mut h, blast, admin, &admin_publication, version, config)?;

    // A native upgrade is possible before wrapping, but its cap can never activate this lineage.
    let (unwrapped, publication) = h.publish(code.clone())?;
    let bootstrap = publication.created(&h, "blast_fun", "Publication")[0];
    let cap = publication.created(&h, "package", "UpgradeCap")[0];
    let config = publication.created(&h, "launch_config", "LaunchConfig")[0];
    let digest = MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true);
    let framework = sui_types::SUI_FRAMEWORK_PACKAGE_ID;
    let mut b = ProgrammableTransactionBuilder::new();
    let cap_arg = b.obj(h.owned(cap))?;
    let policy = b.pure(0u8)?;
    let digest = b.pure(digest.to_vec())?;
    let ticket = call(&mut b, framework, "package", "authorize_upgrade", vec![], vec![cap_arg, policy, digest]);
    let receipt = b.upgrade(unwrapped, ticket, code.dependencies, code.modules);
    call(&mut b, framework, "package", "commit_upgrade", vec![], vec![cap_arg, receipt]);
    let upgraded = h.execute(b.finish())?;
    upgraded.assert_success();
    assert_eq!(bcs::from_bytes::<UpgradeCap>(&h.contents(cap))?.version, 2);
    assert!(upgraded.created(&h, "blast_fun", "PackageVersion").is_empty());
    assert!(upgraded.created(&h, "blast_fun", "Publication").is_empty());
    let mut b = ProgrammableTransactionBuilder::new();
    let bootstrap_arg = b.obj(h.owned(bootstrap))?;
    let cap_arg = b.obj(h.owned(cap))?;
    call(&mut b, unwrapped, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
    h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: admin, module: "upgrade_custody", code: 12 },
        &[bootstrap, cap, config],
        &[h.sender],
    )?;

    Ok(())
}

/// A delay-only proposal waits the old notice; a failed apply-then-schedule PTB rolls back both fields.
fn assert_delay_changes_use_the_old_notice(h: &mut Harness, blast: ObjectID, admin: ObjectID,
    publication: &Outcome, version: ObjectID, config: ObjectID,
) -> Result<()> {
    let cap = h.configuration_admin(admin, publication, blast, "blast_fun_domain", &["FeeAdmin", "CancelAdmin"])?;
    let mut b = ProgrammableTransactionBuilder::new();
    let fee = h.configuration_witness(&mut b, admin, publication, cap, blast, "blast_fun_domain", "FeeAdmin")?;
    let version_arg = b.obj(h.shared(version, false))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let value = b.pure(0u64)?;
    let delay = b.pure(25u64)?;
    call(&mut b, blast, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, value, delay, clock]);
    h.execute(b.finish())?.assert_success();
    let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&h.contents(sui_types::SUI_CLOCK_OBJECT_ID))?;
    h.sim.advance_clock(std::time::Duration::from_millis(172_799_999));
    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, false))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "delayed", code: 17 }, &[config], &[])?;
    h.sim.advance_clock(std::time::Duration::from_millis(1));
    for must_abort in [true, false] {
        let mut b = ProgrammableTransactionBuilder::new();
        let version_arg = b.obj(h.shared(version, false))?;
        let config_arg = b.obj(h.shared(config, true))?;
        let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let fee = h.configuration_witness(&mut b, admin, publication, cap, blast, "blast_fun_domain", "FeeAdmin")?;
        call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
        let value = b.pure(123u64)?;
        let next_delay = b.pure(0u64)?;
        call(&mut b, blast, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, value, next_delay, clock]);
        if must_abort {
            call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
            h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "delayed", code: 17 }, &[config, cap], &[])?;
        } else {
            let applied = h.execute(b.finish())?;
            applied.assert_success();
            let scheduled: Vec<DelayedScheduled<u64>> =
                applied.delayed("DelayedScheduled", "launch_config", "CreationFeeKey")?;
            assert_eq!(scheduled.len(), 1, "scheduled creation fee");
            assert_eq!((scheduled[0].owner, scheduled[0].value), (config, 123));
            assert_eq!((scheduled[0].ready_at_ms, scheduled[0].delay_ms), (scheduled_at_ms + 172_800_000 + 25, 0));
        }
    }
    h.sim.advance_clock(std::time::Duration::from_millis(25));
    let mut b = ProgrammableTransactionBuilder::new();
    let version_arg = b.obj(h.shared(version, false))?;
    let config_arg = b.obj(h.shared(config, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, blast, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
    h.execute(b.finish())?.assert_success();
    let forbidden = h.configuration_admin(admin, publication, blast, "blast_fun_domain", &["TreasuryAdmin"])?;
    let mut b = ProgrammableTransactionBuilder::new();
    h.configuration_witness(&mut b, admin, publication, forbidden, blast, "blast_fun_domain", "FeeAdmin")?;
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "blast_acl", code: 5 }, &[forbidden], &[])?;
    Ok(())
}

/// Real ACL registration activates the agreed share before any Clock advancement.
fn assert_initial_partner_payment(
    h: &mut Harness,
    admin: ObjectID,
    publication: &Outcome,
    partners: ObjectID,
) -> Result<()> {
    let clock_before = h.contents(sui_types::SUI_CLOCK_OBJECT_ID);
    let acl = publication.created(h, "blast_acl", "ACL")[0];
    let root = publication.created(h, "blast_acl", "SuperAdminCap")[0];
    let recipient = SuiAddress::from(ObjectID::from_single_byte(0xFE));
    let framework = sui_types::SUI_FRAMEWORK_PACKAGE_ID;
    let sui = parse_sui_type_tag("0x2::sui::SUI")?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let owner = b.pure(h.sender)?;
    call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, owner]);
    let granted = h.impersonate_cap_owner(root, b.finish())?;
    granted.assert_success();
    let admin_cap = granted.created(h, "blast_acl", "AdminCap")[0];
    let role = parse_sui_type_tag(&format!("{partners}::blast_partners::PartnerAdmin"))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let cap_id = b.pure(admin_cap)?;
    call(&mut b, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, cap_id]);
    h.impersonate_cap_owner(root, b.finish())?.assert_success();

    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, false))?;
    let admin_arg = b.obj(h.owned(admin_cap))?;
    let witness = call(&mut b, admin, "blast_acl", "sign_in", vec![role.clone()], vec![acl_arg, admin_arg]);
    let cap = call(&mut b, partners, "blast_partners", "new_cap", vec![], vec![]);
    let cap_type = parse_sui_type_tag(&format!("{partners}::blast_partners::PartnerCap"))?;
    let cap_id = call(&mut b, framework, "object", "id", vec![cap_type], vec![cap]);
    let recipient_arg = b.pure(recipient)?;
    let share = b.pure(8_000u64)?;
    call(&mut b, partners, "blast_partners", "register", vec![], vec![witness, cap_id, recipient_arg, share]);
    b.transfer_arg(h.sender, cap);
    let registered = h.execute(b.finish())?;
    registered.assert_success();
    let partner = registered.created(h, "blast_partners", "Partner")[0];
    let partner_cap = registered.created(h, "blast_partners", "PartnerCap")[0];

    // The Partner carries both terms as keyed `Delayed` values owned by the partner, applied at
    // once with the fixed notice; `PartnerUpdated` carries only the recipient.
    type Partner = (ObjectID, SuiAddress, Delayed<u64>, Delayed<ObjectID>);
    type Created<T> = (ObjectID, bool, T, u64);
    const NOTICE: u64 = 604_800_000;
    let state: Partner = bcs::from_bytes(&h.contents(partner))?;
    assert_eq!((state.0, state.1), (partner, recipient));
    assert_eq!(state.2, Delayed { owner: partner, key: false, value: 8_000, delay_ms: NOTICE, pending: None });
    assert_eq!(state.3, Delayed { owner: partner, key: false, value: partner_cap, delay_ms: NOTICE, pending: None });
    let updates: Vec<_> = registered.events.iter().filter(|event| event.type_.name.as_str() == "PartnerUpdated").collect();
    assert_eq!(updates.len(), 1);
    assert_eq!(bcs::from_bytes::<(ObjectID, SuiAddress)>(&updates[0].contents)?, (partner, recipient));
    let share_created: Vec<Created<u64>> = registered.delayed("DelayedCreated", "blast_partners", "ShareKey")?;
    let cap_created: Vec<Created<ObjectID>> = registered.delayed("DelayedCreated", "blast_partners", "CapKey")?;
    assert_eq!(share_created, vec![(partner, false, 8_000, NOTICE)]);
    assert_eq!(cap_created, vec![(partner, false, partner_cap, NOTICE)]);

    // Payment reads the applied share and takes no Clock.
    let mut b = ProgrammableTransactionBuilder::new();
    let partner_arg = b.obj(h.shared(partner, false))?;
    let amount = b.pure(1_000u64)?;
    let Argument::Result(split) = b.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
        unreachable!("SplitCoins is a command result");
    };
    let balance = call(&mut b, framework, "coin", "into_balance", vec![sui.clone()], vec![Argument::NestedResult(split, 0)]);
    call(&mut b, partners, "blast_partners", "pay", vec![sui.clone()], vec![partner_arg, balance]);
    let remainder = call(&mut b, framework, "coin", "from_balance", vec![sui.clone()], vec![balance]);
    b.transfer_arg(h.sender, remainder);
    let paid = h.execute(b.finish())?;
    paid.assert_success();
    assert_eq!(paid.coins_created_for(h, recipient), vec![(sui.to_canonical_string(true), 800)]);
    assert_eq!(paid.coins_created_for(h, h.sender), vec![(sui.to_canonical_string(true), 200)]);
    let payments: Vec<_> = paid.events.iter().filter(|event| event.type_.name.as_str() == "PartnerPaid").collect();
    assert_eq!(payments.len(), 1);
    assert_eq!(bcs::from_bytes::<(ObjectID, u64)>(&payments[0].contents)?, (partner, 800));
    assert_eq!(h.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);

    // A real ACL witness proposes; anyone applies after the notice. An abort later in the same PTB
    // rolls back the apply and its event.
    let sign_in = |h: &Harness, b: &mut ProgrammableTransactionBuilder| -> Result<Argument> {
        let acl_arg = b.obj(h.shared(acl, false))?;
        let cap_arg = b.obj(h.owned(admin_cap))?;
        Ok(call(b, admin, "blast_acl", "sign_in", vec![role.clone()], vec![acl_arg, cap_arg]))
    };
    let mut b = ProgrammableTransactionBuilder::new();
    let witness = sign_in(h, &mut b)?;
    let partner_arg = b.obj(h.shared(partner, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let share = b.pure(5_000u64)?;
    call(&mut b, partners, "blast_partners", "schedule_share", vec![], vec![partner_arg, witness, share, clock]);
    let scheduled_outcome = h.execute(b.finish())?;
    scheduled_outcome.assert_success();
    let scheduled: Vec<DelayedScheduled<u64>> = scheduled_outcome.delayed("DelayedScheduled", "blast_partners", "ShareKey")?;
    assert_eq!(scheduled.len(), 1);
    assert_eq!((scheduled[0].owner, scheduled[0].value, scheduled[0].delay_ms), (partner, 5_000, NOTICE));
    let ready_at_ms = scheduled[0].ready_at_ms;
    assert!(scheduled_outcome.events.iter().all(|event| event.type_.name.as_str() != "PartnerUpdated"));
    h.sim.advance_clock(std::time::Duration::from_millis(NOTICE - 1));
    let apply = |h: &Harness| -> Result<_> {
        let mut b = ProgrammableTransactionBuilder::new();
        let partner_arg = b.obj(h.shared(partner, true))?;
        let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, partners, "blast_partners", "apply_share", vec![], vec![partner_arg, clock]);
        Ok(b.finish())
    };
    h.assert_rolled_back(apply(h)?, Expected::Abort { package: admin, module: "delayed", code: 17 }, &[partner], &[h.sender])?;
    h.sim.advance_clock(std::time::Duration::from_millis(1));
    let pending = Some(Proposal { value: 5_000, delay_ms: NOTICE, ready_at_ms });
    assert_eq!(bcs::from_bytes::<Partner>(&h.contents(partner))?.2.pending, pending);
    let mut b = ProgrammableTransactionBuilder::new();
    let partner_arg = b.obj(h.shared(partner, true))?;
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, partners, "blast_partners", "apply_share", vec![], vec![partner_arg, clock]);
    call(&mut b, partners, "blast_partners", "apply_share", vec![], vec![partner_arg, clock]);
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "delayed", code: 18 }, &[partner], &[h.sender])?;
    let ready: Partner = bcs::from_bytes(&h.contents(partner))?;
    assert_eq!((ready.2.value, ready.2.pending), (8_000, pending));

    // Revoking the role blocks cancellation but never the permissionless application.
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let cap_id = b.pure(admin_cap)?;
    call(&mut b, admin, "blast_acl", "revoke_role", vec![role.clone()], vec![acl_arg, root_arg, cap_id]);
    h.impersonate_cap_owner(root, b.finish())?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let witness = sign_in(h, &mut b)?;
    let partner_arg = b.obj(h.shared(partner, true))?;
    call(&mut b, partners, "blast_partners", "cancel_share", vec![], vec![partner_arg, witness]);
    h.assert_rolled_back(b.finish(), Expected::Abort { package: admin, module: "blast_acl", code: 5 }, &[partner, acl, admin_cap], &[h.sender])?;
    let applied = h.execute(apply(h)?)?;
    applied.assert_success();
    let state: Partner = bcs::from_bytes(&h.contents(partner))?;
    assert_eq!(state.2, Delayed { owner: partner, key: false, value: 5_000, delay_ms: NOTICE, pending: None });
    let applied_events: Vec<DelayedApplied<u64>> = applied.delayed("DelayedApplied", "blast_partners", "ShareKey")?;
    assert_eq!(
        applied_events,
        vec![DelayedApplied { owner: partner, key: false, previous_value: 8_000, value: 5_000, delay_ms: NOTICE }],
    );
    assert!(applied.events.iter().all(|event| event.type_.name.as_str() != "PartnerUpdated"));

    Ok(())
}
