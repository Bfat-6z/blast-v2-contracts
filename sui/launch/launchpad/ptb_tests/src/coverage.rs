//! Optional instruction coverage for fork PTBs. Replay each PTB against its
//! pre-transaction state, then require the regular simulator effects to agree.

use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use anyhow::{Context, Result, ensure};
use move_binary_format::file_format_common::Opcodes;
use move_trace_format::{
    format::{Effect, MoveTraceBuilder, TraceEvent},
    interface::{EventFilter, Tracer, Writer},
};
use simulacrum::{Simulacrum, SimulatorStore};
use sui_config::{
    transaction_deny_config::TransactionDenyConfig, verifier_signing_config::VerifierSigningConfig,
};
use sui_types::{
    base_types::ObjectID,
    effects::{TransactionEffects, TransactionEffectsAPI},
    execution_params::ExecutionOrEarlyError,
    message_envelope::Message,
    metrics::{BytecodeVerifierMetrics, ExecutionMetrics},
    signature::VerifyParams,
    sui_system_state::epoch_start_sui_system_state::EpochStartSystemStateTrait,
    transaction::{Transaction, TransactionDataAPI, VerifiedTransaction},
};

use rand::rngs::StdRng;

pub type Hits = BTreeMap<ObjectID, BTreeMap<String, BTreeMap<String, BTreeSet<u16>>>>;

#[derive(Default)]
struct Instructions {
    frames: Vec<(usize, ObjectID, String, String)>,
    hits: Hits,
    error: Option<String>,
}

struct InstructionTracer(Rc<RefCell<Instructions>>);

impl Tracer for InstructionTracer {
    fn notify(&mut self, event: &TraceEvent, _: Writer<'_>) -> bool {
        let mut state = self.0.borrow_mut();
        if state.error.is_some() {
            return false;
        }
        match event {
            TraceEvent::OpenFrame { frame, .. } => {
                state.frames.push((
                    frame.frame_id,
                    frame.version_id.into(),
                    frame.module.name().to_string(),
                    frame.function_name.clone(),
                ));
            }
            TraceEvent::CloseFrame { frame_id, .. } => {
                let frame = state.frames.pop().expect("trace closes an open frame");
                assert_eq!(frame.0, *frame_id);
            }
            TraceEvent::Instruction { pc, .. } => {
                let (_, version, module, function) = state
                    .frames
                    .last()
                    .expect("instruction has a frame")
                    .clone();
                state
                    .hits
                    .entry(version)
                    .or_default()
                    .entry(module)
                    .or_default()
                    .entry(function)
                    .or_default()
                    .insert(*pc);
            }
            TraceEvent::Effect(effect) => {
                if let Effect::ExecutionError(message) = effect.as_ref()
                    && (message.starts_with("!! TRACING ERROR !!")
                        || message.starts_with("VM tracer failed to close instruction"))
                {
                    state.error = Some(message.clone());
                }
            }
            TraceEvent::External(_) => {}
        }
        false
    }

    fn instruction_filter(&self, _: &Opcodes, _: u16) -> Option<EventFilter> {
        None
    }
}

pub(crate) struct Replay {
    output: PathBuf,
    effects: TransactionEffects,
    hits: Hits,
}

#[derive(Default)]
pub(crate) struct ReplayEngine {
    executor: Option<(u64, Arc<dyn sui_execution::Executor + Send + Sync>)>,
}

impl ReplayEngine {
    pub(crate) fn run(
        &mut self,
        sim: &Simulacrum<StdRng>,
        tx: &Transaction,
    ) -> Result<Option<Replay>> {
        let Some(output) = std::env::var_os("BLAST_FORK_COVERAGE_DIR") else {
            return Ok(None);
        };
        ensure!(
            option_env!("BLAST_MOVE_VM_TRACER_PATCHED") == Some("1"),
            "run fork coverage through fork/coverage_cargo.py to apply the pinned tracer fix"
        );
        // Follow the same input checks and execution parameters as the pinned
        // Simulacrum EpochState. The replay does not commit its temporary store.
        let epoch = sim.epoch_start_state();
        let transaction = if tx.data().tx_signatures().is_empty() {
            VerifiedTransaction::new_unchecked(tx.clone())
        } else {
            tx.clone()
                .try_into_verified_for_testing(epoch.epoch(), &VerifyParams::default())?
        };
        let digest = *transaction.digest();
        let tx_data = transaction.data().transaction_data();
        let store = sim.store();
        let inputs = tx_data.input_objects()?;
        let receiving = tx_data.receiving_objects();
        sui_transaction_checks::deny::check_transaction_for_signing(
            tx_data,
            transaction.tx_signatures(),
            &inputs,
            &receiving,
            &TransactionDenyConfig::default(),
            &store,
        )?;
        let (objects, receiving) =
            store.read_objects_for_synchronous_execution(&digest, &inputs, &receiving)?;
        let registry = prometheus::Registry::new();
        let protocol = sim.protocol_config();
        let (gas_status, checked) = sui_transaction_checks::check_transaction_input(
            protocol,
            sim.reference_gas_price(),
            tx_data,
            objects,
            &receiving,
            &BytecodeVerifierMetrics::new(&registry).into(),
            &VerifierSigningConfig::default(),
        )?;
        let (kind, signer, gas_data) = tx_data.execution_parts();
        let state = Rc::new(RefCell::new(Instructions::default()));
        let mut tracer = Some(MoveTraceBuilder::new_with_tracer(Box::new(
            InstructionTracer(state.clone()),
        )));
        if self
            .executor
            .as_ref()
            .is_none_or(|(id, _)| *id != epoch.epoch())
        {
            self.executor = Some((epoch.epoch(), sui_execution::executor(protocol, true)?));
        }
        let (_, executor) = self.executor.as_ref().context("trace replay executor")?;
        let (_, _, effects, _, _) = executor.execute_transaction_to_effects_and_execution_error(
            store.backing_store(),
            protocol,
            ExecutionMetrics::new(&registry).into(),
            false,
            ExecutionOrEarlyError::ok(None),
            &epoch.epoch(),
            epoch.epoch_start_timestamp_ms(),
            checked,
            BTreeMap::new(),
            gas_data,
            gas_status,
            kind,
            None,
            signer,
            digest,
            &mut tracer,
        );
        drop(tracer);
        let instructions = Rc::try_unwrap(state)
            .ok()
            .context("executor retained trace state")?
            .into_inner();
        if let Some(error) = instructions.error {
            anyhow::bail!("transaction {digest}: {error}");
        }
        ensure!(
            !effects.status().is_ok() || instructions.frames.is_empty(),
            "successful transaction {digest} left open trace frames",
        );
        let hits = instructions.hits;
        Ok(Some(Replay {
            output: output.into(),
            effects,
            hits,
        }))
    }
}

impl Replay {
    pub(crate) fn save(self, sim: &Simulacrum<StdRng>, actual: &TransactionEffects) -> Result<()> {
        ensure!(
            self.effects.digest() == actual.digest(),
            "traced effects diverged for {}",
            actual.transaction_digest()
        );
        static NEXT_TRACE: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT_TRACE.fetch_add(1, Ordering::Relaxed);
        let nonce = format!("{}-{sequence}", std::process::id());
        let packages = self.output.join("packages");
        let transactions = self.output.join("transactions");
        fs::create_dir_all(&transactions)?;
        fs::create_dir_all(&packages)?;
        for version in self.hits.keys() {
            let path = packages.join(format!("{version}.bcs"));
            if path.exists() {
                continue;
            }
            let object = sim
                .store()
                .get_object(version)
                .with_context(|| format!("trace package {version}"))?;
            let package = object
                .data
                .try_as_package()
                .context("trace frame package")?;
            write_artifact(
                &path,
                &nonce,
                &bcs::to_bytes(package.serialized_module_map())?,
            )?;
        }
        if !self.hits.is_empty() {
            let path = transactions.join(format!("{}-{nonce}.bcs", actual.transaction_digest()));
            write_artifact(&path, &nonce, &bcs::to_bytes(&self.hits)?)?;
        }
        Ok(())
    }
}

fn write_artifact(path: &Path, nonce: &str, bytes: &[u8]) -> Result<()> {
    let temporary = path.with_extension(format!("{nonce}.tmp"));
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)?;
    Ok(())
}
