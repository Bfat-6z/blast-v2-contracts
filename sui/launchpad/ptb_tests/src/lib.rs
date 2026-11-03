//! In-memory programmable-transaction harness for the launchpad migration seam.
//!
//! Packages are compiled with the pinned `sui` CLI (offline, linked through an ephemeral
//! pubfile) and published into a deterministic `simulacrum` chain. Nothing touches a network.
//!
//! Run from this directory, whose `rust-toolchain.toml` pins the compiler the Sui crates need:
//! `cd sui/launchpad/ptb_tests && cargo test`.
//!
//! The venue-fork tests also insert a committed mainnet snapshot (`fork/`) of real venue
//! packages and objects at their real IDs; see `fork`, `tests/venue_fork.rs`, and
//! `tests/presale_venue_fork.rs`.

pub mod fork;
pub mod measure;

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
    sync::Mutex,
};

use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use move_binary_format::CompiledModule;
use move_core_types::{account_address::AccountAddress, identifier::Identifier, language_storage::StructTag};
use rand::{SeedableRng, rngs::StdRng};
use simulacrum::Simulacrum;
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    crypto::AccountKeyPair,
    effects::{TransactionEffects, TransactionEffectsAPI},
    error::ExecutionError,
    event::Event,
    execution_status::{ExecutionFailureStatus, ExecutionStatus},
    gas_coin::MIST_PER_SUI,
    move_package::UpgradeCap,
    object::{Object, Owner},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{
        Argument, ObjectArg, ProgrammableTransaction, SharedObjectMutability, Transaction,
        TransactionData,
    },
};

/// The Sui revision `Cargo.toml` pins for the simulator. The CLI that compiles the packages must
/// be built from the same revision, or bytecode and framework could disagree.
const PINNED_SUI_REVISION: &str = "51d177ad7d65";
pub const TEST_GENESIS_RECIPIENT: &str = "0xa";
/// The upgrade notice each package's `package_admin::wrap` applies at publication.
pub const PUBLICATION_UPGRADE_NOTICE_MS: u64 = 172_800_000;

/// Keep fixture output with its checkout even when Cargo's compiler cache is shared.
pub fn test_work_dir() -> PathBuf {
    crate_dir().join("target/ptb-fixtures")
}

/// Compiled modules and the on-chain packages they link against.
#[derive(Clone)]
pub struct CompiledPackage {
    pub modules: Vec<Vec<u8>>,
    pub dependencies: Vec<ObjectID>,
}

/// `sui move build` writes each package's `build/` directory, so concurrent tests build in turn.
static BUILD_LOCK: Mutex<()> = Mutex::new(());

/// Compiles `package` offline. `published` maps local dependency sources to the IDs they were
/// published at in the simulator, so the bytecode links against those IDs.
pub fn build(package: &Path, published: &[(&Path, ObjectID)], work: &Path) -> Result<CompiledPackage> {
    let _build = BUILD_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _genesis = GenesisFixture::configure(package)?;
    let mut command = sui_move_build(package, work)?;
    command.args(["--dump", "-e", "mainnet", "--no-tree-shaking"]);
    if !published.is_empty() {
        let mut pubfile = String::from("build-env = \"mainnet\"\nchain-id = \"35834a8a\"\n");
        for (source, id) in published {
            pubfile.push_str(&format!(
                "\n[[published]]\nsource = {{ local = \"{}\" }}\npublished-at = \"{id}\"\noriginal-id = \"{id}\"\nversion = 1\n",
                source.canonicalize()?.display(),
            ));
        }
        let name = package.file_name().context("package directory name")?.to_string_lossy();
        let path = work.join(format!("Pub.{name}.toml"));
        std::fs::write(&path, pubfile)?;
        command.arg("--pubfile-path").arg(path);
    }
    let output = command.output().context("run the sui CLI")?;
    if !output.status.success() {
        bail!(
            "building {} failed:\n{}\n{}",
            package.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    let dump: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let engine = base64::engine::general_purpose::STANDARD;
    let modules = dump["modules"]
        .as_array()
        .context("dump modules")?
        .iter()
        .map(|module| Ok(engine.decode(module.as_str().context("module")?)?))
        .collect::<Result<_>>()?;
    let dependencies = dump["dependencies"]
        .as_array()
        .context("dump dependencies")?
        .iter()
        .map(|id| Ok(ObjectID::from_hex_literal(id.as_str().context("dependency")?)?))
        .collect::<Result<_>>()?;

    Ok(CompiledPackage { modules, dependencies })
}

/// Compiled root modules whose local dependencies still sit at the build's placeholder addresses.
pub struct UnlinkedPackage {
    modules: Vec<CompiledModule>,
    placeholders: BTreeMap<String, AccountAddress>,
}

/// Compiles `package` offline and resets its root address for publication, while linking
/// external venue packages at their pinned `published-at` IDs, which a pubfile cannot name. Each
/// dependency in `local` compiles at a placeholder address that `UnlinkedPackage::link` replaces
/// with the ID it was published at in the simulator.
pub fn build_unlinked(package: &Path, local: &[&str], work: &Path) -> Result<UnlinkedPackage> {
    let _build = BUILD_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let manifest = std::fs::read_to_string(package.join("Move.toml"))?;
    let name = manifest
        .lines()
        .find_map(|line| line.strip_prefix("name = \""))
        .and_then(|rest| rest.strip_suffix('"'))
        .context("package name")?;
    let _genesis = GenesisFixture::configure(package)?;
    let mut command = sui_move_build(package, work)?;
    let output = command.args(["-e", "mainnet"]).output().context("run the sui CLI")?;
    if !output.status.success() {
        bail!(
            "building {} failed:\n{}\n{}",
            package.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    let bytecode = package.join("build").join(name).join("bytecode_modules");
    let read = |directory: &Path| -> Result<Vec<CompiledModule>> {
        let mut modules = Vec::new();
        for entry in std::fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_some_and(|extension| extension == "mv") {
                modules.push(CompiledModule::deserialize_with_defaults(&std::fs::read(path)?)?);
            }
        }
        modules.sort_by_key(|module| module.self_id());
        Ok(modules)
    };
    let mut modules = read(&bytecode)?;
    // Published.toml resolves this root at its historical mainnet address. A simulator
    // publication needs zero-address root modules, including their mutual references.
    let root = *modules.first().context("root modules")?.self_id().address();
    for module in &mut modules {
        ensure!(*module.self_id().address() == root, "one root package address");
        for address in &mut module.address_identifiers {
            if *address == root {
                *address = AccountAddress::ZERO;
            }
        }
    }
    let mut placeholders = BTreeMap::new();
    for dependency in local {
        let module = read(&bytecode.join("dependencies").join(dependency))?
            .into_iter()
            .next()
            .with_context(|| format!("{dependency} modules"))?;
        placeholders.insert(dependency.to_string(), *module.self_id().address());
    }

    Ok(UnlinkedPackage { modules, placeholders })
}

impl UnlinkedPackage {
    /// Rewrites each placeholder to the ID `published` gives its dependency and returns the
    /// package ready to publish against `dependencies`.
    pub fn link(&self, published: &[(&str, ObjectID)], dependencies: Vec<ObjectID>) -> Result<CompiledPackage> {
        let mut replacements = BTreeMap::new();
        for (name, id) in published {
            let placeholder = self.placeholders.get(*name).with_context(|| format!("placeholder for {name}"))?;
            replacements.insert(*placeholder, AccountAddress::from(*id));
        }
        ensure!(replacements.len() == self.placeholders.len(), "every local dependency needs an ID");
        let modules = self
            .modules
            .iter()
            .map(|module| {
                let mut module = module.clone();
                for address in module.address_identifiers.iter_mut() {
                    if let Some(id) = replacements.get(address) {
                        *address = *id;
                    }
                }
                let mut bytes = Vec::new();
                module.serialize_with_version(module.version, &mut bytes)?;
                Ok(bytes)
            })
            .collect::<Result<_>>()?;

        Ok(CompiledPackage { modules, dependencies })
    }
}

/// Compile simulator packages with an explicit nonzero genesis recipient, restoring the source.
/// Callers hold BUILD_LOCK until compilation completes.
struct GenesisFixture { path: PathBuf, original: String }
impl GenesisFixture {
    fn configure(package: &Path) -> Result<Self> {
        let path = package.join("Move.toml");
        let original = std::fs::read_to_string(&path)?;
        let fixture = original.replace("blast_treasury = \"0x0\"", &format!("blast_treasury = \"{TEST_GENESIS_RECIPIENT}\""))
            .replace("blast_lp_fee_destination = \"0x0\"", &format!("blast_lp_fee_destination = \"{TEST_GENESIS_RECIPIENT}\""));
        std::fs::write(&path, fixture)?;
        Ok(Self { path, original })
    }
}
impl Drop for GenesisFixture {
    fn drop(&mut self) { std::fs::write(&self.path, &self.original).expect("restore genesis fixture manifest"); }
}

/// Advance the simulator through the administrative delay, then execute public apply calls.
pub fn apply_admin_changes(
    h: &mut Harness,
    changes: Vec<(ObjectID, &str, &str, Vec<sui_types::TypeTag>, ObjectID, ObjectID)>,
) -> Result<()> {
    h.sim.advance_clock(std::time::Duration::from_millis(172_800_000));
    let mut b = ProgrammableTransactionBuilder::new();
    let clock = b.obj(h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    for (package, module, function, types, object, version) in changes {
        let object = b.obj(h.shared(object, true))?;
        let version = b.obj(h.shared(version, false))?;
        call(&mut b, package, module, function, types, vec![object, version, clock]);
    }
    h.execute(b.finish())?.assert_success();
    Ok(())
}

/// A `sui move build` command under the pinned CLI and an offline client config.
fn sui_move_build(package: &Path, work: &Path) -> Result<Command> {
    let binary = std::env::var("SUI_BINARY").unwrap_or_else(|_| "sui".into());
    let version = Command::new(&binary).arg("--version").output().context("run the sui CLI")?;
    let version = String::from_utf8_lossy(&version.stdout);
    ensure!(
        version.contains(PINNED_SUI_REVISION),
        "`{binary} --version` is {}; the harness needs revision {PINNED_SUI_REVISION}",
        version.trim(),
    );
    std::fs::create_dir_all(work)?;
    let client = work.join("client.yaml");
    std::fs::write(
        &client,
        "---\nkeystore:\n  File: ~\nenvs:\n  - alias: offline\n    rpc: \"http://127.0.0.1:1\"\n    ws: ~\n    basic_auth: ~\nactive_env: offline\nactive_address: \"0x0000000000000000000000000000000000000000000000000000000000000000\"\n",
    )?;
    let mut command = Command::new(&binary);
    command.arg("move").arg("--client.config").arg(&client).arg("build").arg("--path").arg(package);

    Ok(command)
}

// === blast_admin delayed-module mirrors (BCS field order) ===
//
// Every key is a zero-field positional struct such as `TradeFeesKey()`, which Move compiles with
// one `dummy_field: bool`, so each `key` is one BCS byte.

/// The `blast_admin` modules that emit delayed lifecycle events: settings in `delayed`, one-shot
/// actions in `delayed_action`, allowlists in `delayed_set` and keyed values in `delayed_map`.
/// Their event names are distinct, so a name alone selects one module's event.
pub const DELAYED_MODULES: [&str; 4] = ["delayed", "delayed_action", "delayed_set", "delayed_map"];

/// Whether `module` is one of `blast_admin`'s delayed modules.
pub fn is_delayed_module(module: &str) -> bool {
    DELAYED_MODULES.contains(&module)
}

/// Mirrors `blast_admin::delayed::Proposal<T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct Proposal<T> {
    pub value: T,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::Change<A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub enum Change<A> {
    Action(A),
    Delay,
}

/// Mirrors `blast_admin::delayed::Delayed<K, T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct Delayed<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub value: T,
    pub delay_ms: u64,
    pub pending: Option<Proposal<T>>,
}

/// Mirrors `blast_admin::delayed::Notice`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct Notice {
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::DelayedSet<K, E>`, its `VecSet` and `VecMap` flattened.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedSet<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub members: Vec<E>,
    pub delay_ms: u64,
    pub admissions: Vec<(E, Notice)>,
    pub pending_delay: Option<Notice>,
}

/// A `RuntimeConfig` in BCS field order: claim signers, protocol fee share and treasury.
pub type RuntimeConfigContents = (ObjectID, DelayedSet<Vec<u8>>, Delayed<u64>, Delayed<SuiAddress>);

/// Mirrors `blast_admin::delayed_action::DelayedAction<K, A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedAction<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub delay_ms: u64,
    pub pending: Option<Proposal<Change<A>>>,
}

/// Mirrors `blast_fun_migrators::vault::RoundTerms` and `blast_presale::presale_vault::RoundTerms`,
/// the terms a vault's round-publication slot holds until anyone publishes the round.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct RoundTerms {
    pub number: u64,
    pub start_checkpoint: u64,
    pub end_checkpoint: u64,
    pub root: Vec<u8>,
    pub manifest_digest: Vec<u8>,
    pub leaf_count: u64,
    pub meme_amount: u64,
    pub quote_amount: u64,
    pub gas_reserve_amount: u64,
    pub claim_window_duration_ms: u64,
    pub expected_treasury: SuiAddress,
}

/// Mirrors each package's `package_admin::UpgradeAction`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub enum UpgradeAction {
    Upgrade(Vec<u8>),
    MakeImmutable,
}

/// A `PackageAdmin` in BCS field order, with its `UpgradeCustody` flattened.
pub type PackageAdminContents = (ObjectID, (ObjectID, String, String), Vec<UpgradeCap>, DelayedAction<UpgradeAction>);

/// Mirrors `blast_admin::delayed::DelayedScheduled<K, T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedScheduled<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub value: T,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed::DelayedApplied<K, T>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct DelayedApplied<T> {
    pub owner: ObjectID,
    pub key: bool,
    pub previous_value: T,
    pub value: T,
    pub delay_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::ActionScheduled<K, A>` and `ActionCancelled<K, A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct ActionScheduled<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: Change<A>,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_action::ActionApplied<K, A>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct ActionApplied<A> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: Change<A>,
    pub delay_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::SetChange<E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub enum SetChange<E> {
    Admission(E),
    Delay,
}

/// Mirrors `blast_admin::delayed_set::SetScheduled<K, E>` and `SetCancelled<K, E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct SetScheduled<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: SetChange<E>,
    pub delay_ms: u64,
    pub ready_at_ms: u64,
}

/// Mirrors `blast_admin::delayed_set::SetApplied<K, E>`.
#[derive(serde::Deserialize, Debug, Clone, PartialEq)]
pub struct SetApplied<E> {
    pub owner: ObjectID,
    pub key: bool,
    pub change: SetChange<E>,
    pub delay_ms: u64,
}

/// Everything one executed transaction produced.
pub struct Outcome {
    pub transaction: Transaction,
    pub effects: TransactionEffects,
    pub error: Option<ExecutionError>,
    pub events: Vec<Event>,
}

impl Outcome {
    pub fn assert_success(&self) -> &Self {
        assert!(
            self.effects.status().is_ok(),
            "transaction failed: {:?} {:?}",
            self.effects.status(),
            self.error
        );
        self
    }

    /// IDs of created objects whose type is `module::name`.
    pub fn created(&self, harness: &Harness, module: &str, name: &str) -> Vec<ObjectID> {
        self.effects
            .created()
            .into_iter()
            .map(|(object, _)| object.0)
            .filter(|id| harness.is_type(*id, module, name))
            .collect()
    }

    /// Payload bytes of Blast events whose payload type is `module::name`. Blast wraps every
    /// payload in `blast_events::Event<T>`, whose BCS encoding is the payload's.
    pub fn events_of(&self, module: &str, name: &str) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter(|event| {
                event.type_.module.as_str() == "blast_events"
                    && event.type_.name.as_str() == "Event"
                    && matches!(
                        event.type_.type_params.as_slice(),
                        [sui_types::TypeTag::Struct(payload)]
                            if payload.module.as_str() == module && payload.name.as_str() == name
                    )
            })
            .map(|event| event.contents.as_slice())
            .collect()
    }

    /// Contents of the `<name>` lifecycle events of `blast_admin`'s delayed modules keyed by
    /// `key_module::key_name`, in native order. The primitives emit these bare, generic in the
    /// owner's key type.
    pub fn delayed_events(&self, name: &str, key_module: &str, key_name: &str) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter(|event| {
                is_delayed_module(event.type_.module.as_str())
                    && event.type_.name.as_str() == name
                    && matches!(
                        event.type_.type_params.first(),
                        Some(sui_types::TypeTag::Struct(key))
                            if key.module.as_str() == key_module && key.name.as_str() == key_name
                    )
            })
            .map(|event| event.contents.as_slice())
            .collect()
    }

    /// Decodes `delayed_events` into a mirror, which must consume each payload exactly.
    pub fn delayed<T: serde::de::DeserializeOwned>(
        &self, name: &str, key_module: &str, key_name: &str,
    ) -> Result<Vec<T>> {
        self.delayed_events(name, key_module, key_name)
            .into_iter()
            .map(|bytes| bcs::from_bytes(bytes).with_context(|| format!("decode {name}<{key_module}::{key_name}>")))
            .collect()
    }

    /// Payload type names of every Blast event, in native order. Each must be a `package` payload
    /// inside `package`'s `blast_events::Event<T>` envelope, so a bare or foreign event fails. The
    /// only exception is a lifecycle event of a `blast_admin` delayed module keyed by a `package`
    /// type, which is bare by design and skipped here; read it with `delayed_events`.
    pub fn wrapped_payloads(&self, package: ObjectID) -> Vec<String> {
        self.events
            .iter()
            .filter(|event| {
                !(is_delayed_module(event.type_.module.as_str())
                    && matches!(
                        event.type_.type_params.first(),
                        Some(sui_types::TypeTag::Struct(key)) if ObjectID::from(key.address) == package
                    ))
            })
            .map(|event| {
                let envelope = &event.type_;
                assert!(
                    ObjectID::from(envelope.address) == package
                        && envelope.module.as_str() == "blast_events"
                        && envelope.name.as_str() == "Event",
                    "event {envelope} is not in the launchpad envelope"
                );
                let [sui_types::TypeTag::Struct(payload)] = envelope.type_params.as_slice() else {
                    panic!("envelope {envelope} does not carry exactly one payload");
                };
                assert_eq!(ObjectID::from(payload.address), package, "foreign payload {payload}");
                payload.name.to_string()
            })
            .collect()
    }

    /// Canonical coin type and value of every coin this transaction created for `owner`, sorted.
    pub fn coins_created_for(&self, harness: &Harness, owner: SuiAddress) -> Vec<(String, u64)> {
        let mut coins: Vec<_> = self
            .effects
            .created()
            .into_iter()
            .filter(|(_, created_owner)| *created_owner == Owner::AddressOwner(owner))
            .map(|(object, _)| {
                let coin = harness.object(object.0);
                let tag = coin.coin_type_maybe().expect("coin").to_canonical_string(true);
                (tag, coin.get_coin_value_unsafe())
            })
            .collect();
        coins.sort();
        coins
    }
}

/// Every Move object's type and contents, plus the address-owned object IDs of the watched
/// addresses. A failed transaction must leave this unchanged.
#[derive(Debug, PartialEq, Eq)]
pub struct Snapshot {
    objects: BTreeMap<ObjectID, (StructTag, Vec<u8>)>,
    owned: BTreeMap<SuiAddress, Vec<ObjectID>>,
}

pub struct Harness {
    pub sim: Simulacrum<StdRng>,
    pub sender: SuiAddress,
    key: AccountKeyPair,
    gas: ObjectID,
}

impl Harness {
    pub fn new() -> Result<Self> {
        let mut sim = Simulacrum::new_with_rng(StdRng::seed_from_u64(0xB1A57));
        let (sender, key, gas) = sim.funded_account(1_000 * MIST_PER_SUI)?;
        Ok(Self { sim, sender, key, gas: gas.0 })
    }

    pub fn gas_id(&self) -> ObjectID {
        self.gas
    }

    pub fn object(&self, id: ObjectID) -> Object {
        self.sim
            .store()
            .get_object(&id)
            .cloned()
            .unwrap_or_else(|| panic!("object {id} is missing"))
    }

    pub fn contents(&self, id: ObjectID) -> Vec<u8> {
        self.object(id).data.try_as_move().expect("Move object").contents().to_vec()
    }

    pub fn is_type(&self, id: ObjectID, module: &str, name: &str) -> bool {
        self.object(id)
            .data
            .try_as_move()
            .map(|object| {
                let tag: StructTag = object.type_().clone().into();
                tag.module.as_str() == module && tag.name.as_str() == name
            })
            .unwrap_or(false)
    }

    /// Writes `object` into the store as is, at its own ID and version.
    pub fn insert(&mut self, object: Object) {
        self.sim.store_mut().update_objects(BTreeMap::from([(object.id(), object)]), vec![]);
    }

    pub fn owned_by(&self, owner: SuiAddress) -> Vec<Object> {
        self.sim.store().owned_objects(owner).cloned().collect()
    }

    pub fn owned_of_type(&self, owner: SuiAddress, module: &str, name: &str) -> Vec<ObjectID> {
        self.owned_by(owner)
            .into_iter()
            .map(|object| object.id())
            .filter(|id| self.is_type(*id, module, name))
            .collect()
    }

    pub fn shared(&self, id: ObjectID, mutable: bool) -> ObjectArg {
        let Owner::Shared { initial_shared_version } = self.object(id).owner().clone() else {
            panic!("object {id} is not shared");
        };
        ObjectArg::SharedObject {
            id,
            initial_shared_version,
            mutability: if mutable {
                SharedObjectMutability::Mutable
            } else {
                SharedObjectMutability::Immutable
            },
        }
    }

    pub fn owned(&self, id: ObjectID) -> ObjectArg {
        ObjectArg::ImmOrOwnedObject(self.object(id).compute_object_reference())
    }

    pub fn execute(&mut self, pt: ProgrammableTransaction) -> Result<Outcome> {
        let gas = self.object(self.gas).compute_object_reference();
        let data = TransactionData::new_programmable(
            self.sender,
            vec![gas],
            pt,
            50 * MIST_PER_SUI,
            self.sim.reference_gas_price(),
        );
        let transaction = Transaction::from_data_and_signer(data, vec![&self.key]);
        let (effects, error) = self.sim.execute_transaction(transaction.clone())?;
        let events = self
            .sim
            .store()
            .get_transaction_events(effects.transaction_digest())
            .map(|events| events.data.clone())
            .unwrap_or_default();

        Ok(Outcome { transaction, effects, error, events })
    }

    /// Simulates the configured capability owner for fixture setup, without its private key.
    /// Ownership checks still run; this provides no evidence about real root signatures.
    pub fn impersonate_cap_owner(&mut self, cap: ObjectID, pt: ProgrammableTransaction) -> Result<Outcome> {
        let sender = self.object(cap).owner().get_address_owner_address()?;
        let funded = self.sim.request_gas(sender, 100 * MIST_PER_SUI)?;
        ensure!(funded.status().is_ok(), "fund capability owner");
        let gas = funded.created().into_iter()
            .find_map(|(object, owner)| (owner == Owner::AddressOwner(sender)).then_some(object))
            .context("capability owner's gas")?;
        let data = TransactionData::new_programmable(
            sender, vec![gas], pt, 50 * MIST_PER_SUI, self.sim.reference_gas_price(),
        );
        let transaction = Transaction::from_data(data, vec![]);
        let (effects, error) = self.sim.execute_transaction_impersonating(transaction.clone())?;
        let events = self.sim.store().get_transaction_events(effects.transaction_digest())
            .map(|events| events.data.clone()).unwrap_or_default();

        Ok(Outcome { transaction, effects, error, events })
    }

    /// Publishes upgradeably and keeps the UpgradeCap with the sender.
    pub fn publish(&mut self, package: CompiledPackage) -> Result<(ObjectID, Outcome)> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let cap = builder.publish_upgradeable(package.modules, package.dependencies);
        builder.transfer_arg(self.sender, cap);
        let outcome = self.execute(builder.finish())?;
        outcome.assert_success();
        let published = outcome.effects.published_packages();
        ensure!(published.len() == 1, "expected one published package");

        Ok((published[0], outcome))
    }

    /// Configures initial admission and seals custody; operations remain paused until release.
    pub fn wrap_launchpad(&mut self, package: ObjectID, publication: &Outcome, admin: ObjectID, admin_publication: &Outcome, quote: sui_types::TypeTag, witness: sui_types::TypeTag) -> Result<(ObjectID, ObjectID)> {
        assert!(publication.created(self, "blast_fun", "PackageVersion").is_empty());
        let config_id = publication.created(self, "launch_config", "LaunchConfig")[0];
        let runtime_id = publication.created(self, "runtime_config", "RuntimeConfig")[0];
        let bootstrap = publication.created(self, "blast_fun", "Publication");
        let cap = publication.created(self, "package", "UpgradeCap");
        assert_eq!(bootstrap.len(), 1);
        assert_eq!(cap.len(), 1);
        let (bootstrap_id, publisher, generation): (ObjectID, (ObjectID, String, String), u64) =
            bcs::from_bytes(&self.contents(bootstrap[0]))?;
        let cap_contents = self.contents(cap[0]);
        let mut builder = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = builder.obj(self.owned(bootstrap[0]))?;
        let cap_arg = builder.obj(self.owned(cap[0]))?;
        call(&mut builder, package, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
        let outcome = self.execute(builder.finish())?;
        outcome.assert_success();
        assert_eq!(outcome.effects.deleted().iter().map(|object| object.0).collect::<Vec<_>>(), vec![bootstrap_id]);
        // The simulator retains wrapped objects in its cache; transaction effects establish custody.
        assert_eq!(outcome.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>(), cap);
        let version = outcome.created(self, "blast_fun", "PackageVersion");
        assert_eq!(version.len(), 1);
        let package_admin = outcome.created(self, "package_admin", "PackageAdmin");
        assert_eq!(package_admin.len(), 1);
        self.shared(package_admin[0], false);
        let (admin_id, sealed_publisher, sealed_caps, upgrade) = self.package_admin(package_admin[0])?;
        assert!(upgrade.pending.is_none(), "fresh custody has no scheduled action");
        assert_eq!(upgrade.delay_ms, PUBLICATION_UPGRADE_NOTICE_MS, "publication starts at the 48-hour upgrade notice");
        assert_eq!(upgrade.owner, package_admin[0]);
        assert_eq!(admin_id, package_admin[0]);
        assert_eq!(sealed_publisher, publisher);
        assert_eq!(sealed_caps.len(), 1);
        assert_eq!(bcs::to_bytes(&sealed_caps[0])?, cap_contents);
        let (version_id, paused, active_generation): (ObjectID, u8, u64) =
            bcs::from_bytes(&self.contents(version[0])).context("decode fresh PackageVersion")?;
        assert_eq!((version_id, paused, active_generation), (version[0], 7, generation));
        let (_, signers, _, treasury): RuntimeConfigContents =
            bcs::from_bytes(&self.contents(runtime_id)).context("decode fresh RuntimeConfig")?;
        assert!(signers.members.is_empty() && signers.admissions.is_empty(), "publication admits no claim signer");
        assert_eq!(signers.delay_ms, 0, "publication starts the signer notice at zero");
        let config_cap = self.configuration_admin(admin, admin_publication, package, "blast_fun_domain", &["ListingAdmin", "AdapterAdmin", "FeeAdmin", "TreasuryAdmin"])?;
        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(self.shared(config_id, true))?;
        let version_arg = b.obj(self.shared(version[0], false))?;
        let clock = b.obj(self.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let listing = self.configuration_witness(&mut b, admin, admin_publication, config_cap, package, "blast_fun_domain", "ListingAdmin")?;
        let adapter = self.configuration_witness(&mut b, admin, admin_publication, config_cap, package, "blast_fun_domain", "AdapterAdmin")?;
        let allowed = b.pure(true)?;
        call(&mut b, package, "launch_config", "set_quote_allowed", vec![quote], vec![config, version_arg, listing, allowed]);
        call(&mut b, package, "launch_config", "schedule_migration_witness", vec![witness.clone()], vec![config, version_arg, adapter, clock]);
        call(&mut b, package, "launch_config", "apply_migration_witness", vec![witness], vec![config, version_arg, clock]);
        let delay = b.pure(172_800_000u64)?;
        call(&mut b, package, "launch_config", "schedule_migration_delay", vec![], vec![config, version_arg, adapter, delay, clock]);
        call(&mut b, package, "launch_config", "apply_migration_delay", vec![], vec![config, version_arg, clock]);
        self.execute(b.finish())?.assert_success();
        // Set independent operation notices during publication setup using ordinary ACL roles.
        let mut b = ProgrammableTransactionBuilder::new();
        let config_arg = b.obj(self.shared(config_id, true))?;
        let runtime = b.obj(self.shared(runtime_id, true))?;
        let version_arg = b.obj(self.shared(version[0], false))?;
        let clock = b.obj(self.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let fee = self.configuration_witness(&mut b, admin, admin_publication, config_cap, package, "blast_fun_domain", "FeeAdmin")?;
        let treasury_role = self.configuration_witness(&mut b, admin, admin_publication, config_cap, package, "blast_fun_domain", "TreasuryAdmin")?;
        let zero = b.pure(0u64)?;
        let delay = b.pure(172_800_000u64)?;
        let destination = b.pure(treasury.value)?;
        call(&mut b, package, "launch_config", "schedule_creation_fee", vec![], vec![config_arg, version_arg, fee, zero, delay, clock]);
        call(&mut b, package, "launch_config", "apply_creation_fee", vec![], vec![config_arg, version_arg, clock]);
        call(&mut b, package, "runtime_config", "schedule_treasury", vec![], vec![runtime, version_arg, treasury_role, destination, delay, clock]);
        call(&mut b, package, "runtime_config", "apply_treasury", vec![], vec![runtime, version_arg, clock]);
        self.execute(b.finish())?.assert_success();
        Ok((version[0], package_admin[0]))
    }

    /// Creates a real ACL administrator for initial zero-delay configuration.
    pub fn configuration_admin(&mut self, admin: ObjectID, publication: &Outcome, package: ObjectID,
        domain: &str, roles: &[&str],
    ) -> Result<ObjectID> {
        let acl = publication.created(self, "blast_acl", "ACL")[0];
        let root = publication.created(self, "blast_acl", "SuperAdminCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let recipient = b.pure(self.sender)?;
        call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
        let granted = self.impersonate_cap_owner(root, b.finish())?;
        granted.assert_success();
        let cap = granted.created(self, "blast_acl", "AdminCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let cap_id = b.pure(cap)?;
        for role in roles {
            let role = sui_types::parse_sui_type_tag(&format!("{package}::{domain}::{role}"))?;
            call(&mut b, admin, "blast_acl", "grant_role", vec![role], vec![acl_arg, root_arg, cap_id]);
        }
        self.impersonate_cap_owner(root, b.finish())?.assert_success();
        Ok(cap)
    }

    pub fn configuration_witness(&self, b: &mut ProgrammableTransactionBuilder, admin: ObjectID,
        publication: &Outcome, cap: ObjectID, package: ObjectID, domain: &str, role: &str,
    ) -> Result<Argument> {
        let acl = publication.created(self, "blast_acl", "ACL")[0];
        let acl_arg = b.obj(self.shared(acl, false))?;
        let cap_arg = b.obj(self.owned(cap))?;
        let role = sui_types::parse_sui_type_tag(&format!("{package}::{domain}::{role}"))?;
        Ok(call(b, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, cap_arg]))
    }

    /// Decodes any package's `PackageAdmin`: its id, sealed Publisher, sealed caps and upgrade slot.
    pub fn package_admin(&self, custody: ObjectID) -> Result<PackageAdminContents> {
        bcs::from_bytes(&self.contents(custody)).context("decode PackageAdmin")
    }

    /// A fresh `PackageAdmin` waits the 48-hour publication notice with nothing scheduled.
    pub fn assert_publication_upgrade_notice(&self, custody: ObjectID) -> Result<()> {
        let (admin_id, _, sealed_caps, upgrade) = self.package_admin(custody)?;
        ensure!(admin_id == custody && upgrade.owner == custody && sealed_caps.len() == 1);
        ensure!(upgrade.pending.is_none(), "fresh custody has no scheduled action");
        ensure!(upgrade.delay_ms == PUBLICATION_UPGRADE_NOTICE_MS, "publication starts at the 48-hour upgrade notice");
        Ok(())
    }

    /// Migrators shares no operational version until its one-time Publication enters custody.
    pub fn wrap_migrators(&mut self, package: ObjectID, publication: &Outcome) -> Result<ObjectID> {
        assert!(publication.created(self, "blast_fun_migrators", "PackageVersion").is_empty());
        let bootstrap = publication.created(self, "blast_fun_migrators", "Publication")[0];
        let cap = publication.created(self, "package", "UpgradeCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = b.obj(self.owned(bootstrap))?;
        let cap_arg = b.obj(self.owned(cap))?;
        call(&mut b, package, "package_admin", "wrap", vec![], vec![bootstrap_arg, cap_arg]);
        let outcome = self.execute(b.finish())?;
        outcome.assert_success();
        assert!(outcome.effects.deleted().iter().any(|object| object.0 == bootstrap));
        let version = outcome.created(self, "blast_fun_migrators", "PackageVersion");
        assert_eq!(version.len(), 1);
        let package_admin = outcome.created(self, "package_admin", "PackageAdmin");
        assert_eq!(package_admin.len(), 1);
        self.assert_publication_upgrade_notice(package_admin[0])?;
        Ok(version[0])
    }

    /// Uses the real ACL and immediate UnpauseAdmin path without advancing the Clock.
    pub fn unpause(&mut self, package: ObjectID, marker: &str, admin: ObjectID,
        publication: &Outcome, version: ObjectID, bits: u8,
    ) -> Result<()> {
        let acl = publication.created(self, "blast_acl", "ACL")[0];
        let root = publication.created(self, "blast_acl", "SuperAdminCap")[0];
        let domain = if marker == "blast_fun" { "blast_fun_domain" } else { "blast_presale_domain" };
        let role = sui_types::parse_sui_type_tag(&format!("{package}::{domain}::UnpauseAdmin"))?;
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let recipient = b.pure(self.sender)?;
        call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
        let granted = self.impersonate_cap_owner(root, b.finish())?;
        granted.assert_success();
        let cap = granted.created(self, "blast_acl", "AdminCap")[0];
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, true))?;
        let root_arg = b.obj(self.owned(root))?;
        let cap_id = b.pure(cap)?;
        call(&mut b, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, cap_id]);
        self.impersonate_cap_owner(root, b.finish())?.assert_success();
        let clock_before = self.contents(sui_types::SUI_CLOCK_OBJECT_ID);
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(self.shared(acl, false))?;
        let cap_arg = b.obj(self.owned(cap))?;
        let witness = call(&mut b, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, cap_arg]);
        let version_arg = b.obj(self.shared(version, true))?;
        let bits = b.pure(bits)?;
        call(&mut b, package, marker, "unpause", vec![], vec![version_arg, witness, bits]);
        self.execute(b.finish())?.assert_success();
        assert_eq!(self.contents(sui_types::SUI_CLOCK_OBJECT_ID), clock_before);
        Ok(())
    }

    pub fn snapshot(&self, objects: &[ObjectID], owners: &[SuiAddress]) -> Snapshot {
        Snapshot {
            objects: objects
                .iter()
                .map(|id| {
                    let object = self.object(*id);
                    let object = object.data.try_as_move().expect("Move object");
                    (*id, (object.type_().clone().into(), object.contents().to_vec()))
                })
                .collect(),
            owned: owners
                .iter()
                .map(|owner| {
                    let mut ids: Vec<_> = self.owned_by(*owner).iter().map(|object| object.id()).collect();
                    ids.sort();
                    (*owner, ids)
                })
                .collect(),
        }
    }

    /// Executes `pt`, requires it to fail as `expected`, and proves the failure committed nothing:
    /// no object created, deleted, wrapped, or unwrapped; no event; every mutated input other than
    /// gas is one of `objects` and all of `objects` and the `owners`' inventories are unchanged.
    pub fn assert_rolled_back(
        &mut self,
        pt: ProgrammableTransaction,
        expected: Expected,
        objects: &[ObjectID],
        owners: &[SuiAddress],
    ) -> Result<()> {
        let before = self.snapshot(objects, owners);
        let outcome = self.execute(pt)?;
        match (outcome.effects.status(), &expected) {
            (ExecutionStatus::Failure(failure), expected) => {
                assert!(
                    expected.matches(&failure.error),
                    "expected failure {expected:?}, got {:?} in command {:?}",
                    failure.error,
                    failure.command
                );
            }
            (ExecutionStatus::Success, _) => panic!("expected failure {expected:?}, but it succeeded"),
        }
        let effects = &outcome.effects;
        assert!(effects.created().is_empty(), "failed transaction created objects");
        assert!(effects.deleted().is_empty(), "failed transaction deleted objects");
        assert!(effects.wrapped().is_empty(), "failed transaction wrapped objects");
        assert!(effects.unwrapped().is_empty(), "failed transaction unwrapped objects");
        assert!(effects.unwrapped_then_deleted().is_empty(), "failed transaction unwrapped objects");
        assert!(outcome.events.is_empty(), "failed transaction emitted events");
        for (object, _) in effects.mutated() {
            assert!(
                object.0 == self.gas || objects.contains(&object.0),
                "failed transaction touched unwatched object {}",
                object.0
            );
        }
        assert_eq!(self.snapshot(objects, owners), before, "failed transaction changed state");

        Ok(())
    }
}

/// The failure a rolled-back transaction must report.
#[derive(Debug)]
pub enum Expected {
    /// `MoveAbort` with `code` from `package::module`.
    Abort { package: ObjectID, module: &'static str, code: u64 },
    /// Any other failure whose rendered error contains the text.
    Error(&'static str),
}

impl Expected {
    fn matches(&self, error: &ExecutionFailureStatus) -> bool {
        match (self, error) {
            (Expected::Abort { package, module, code }, ExecutionFailureStatus::MoveAbort(location, abort)) => {
                *location.module.address() == AccountAddress::from(*package)
                    && location.module.name().as_str() == *module
                    && abort_code(*abort) == *code
            }
            (Expected::Abort { .. }, _) => false,
            (Expected::Error(text), error) => format!("{error:?}").contains(text),
        }
    }
}

/// The error code of a Move abort: a plain code as is, and the `code` of an `#[error(code = N)]`
/// constant from the tagged value such an abort carries (bit 63 set, code in bits 48..56).
fn abort_code(abort: u64) -> u64 {
    if abort >> 63 == 1 { (abort >> 48) & 0xFF } else { abort }
}

/// Shorthand for a Move call with `Identifier` names.
pub fn call(
    builder: &mut ProgrammableTransactionBuilder,
    package: ObjectID,
    module: &str,
    function: &str,
    type_arguments: Vec<sui_types::TypeTag>,
    arguments: Vec<Argument>,
) -> Argument {
    builder.programmable_move_call(
        package,
        Identifier::new(module).expect("module name"),
        Identifier::new(function).expect("function name"),
        type_arguments,
        arguments,
    )
}

/// Cargo runs integration tests from the crate root of the selected checkout.
/// A cached binary can have been compiled in a different checkout.
pub fn crate_dir() -> PathBuf {
    let dir = std::env::current_dir().expect("native PTB test working directory");
    assert!(
        dir.join("Cargo.toml").is_file() && dir.ends_with("launchpad/ptb_tests"),
        "run native PTB tests from the launchpad/ptb_tests crate: {}",
        dir.display(),
    );
    dir
}

/// The repository's `sui/` directory.
pub fn sui_dir() -> PathBuf {
    crate_dir().join("../..").canonicalize().expect("sui directory")
}

/// The local immutable timelock package linked by `blast_partners`.
pub fn timelock_dir() -> Result<PathBuf> {
    Ok(sui_dir().join("timelock").canonicalize()?)
}

/// The local immutable vesting package linked by `blast_presale`.
pub fn vesting_dir() -> Result<PathBuf> {
    Ok(sui_dir().join("vesting").canonicalize()?)
}

/// Compiles the timelock from a copy in `work`, so building never writes into the source package.
pub fn build_timelock(work: &Path) -> Result<CompiledPackage> {
    build_copy(&timelock_dir()?, "blast_fun_timelock", work)
}

/// Compiles the vesting package from a copy in `work`, unpublished, as the timelock is.
pub fn build_vesting(work: &Path) -> Result<CompiledPackage> {
    build_copy(&vesting_dir()?, "blast_fun_vesting", work)
}

fn build_copy(source: &Path, name: &str, work: &Path) -> Result<CompiledPackage> {
    let copy = work.join(name);
    std::fs::create_dir_all(copy.join("sources"))?;
    std::fs::copy(source.join("Move.toml"), copy.join("Move.toml"))?;
    for entry in std::fs::read_dir(source.join("sources"))? {
        let path = entry?.path();
        std::fs::copy(&path, copy.join("sources").join(path.file_name().context("source name")?))?;
    }

    build(&copy, &[], work)
}
