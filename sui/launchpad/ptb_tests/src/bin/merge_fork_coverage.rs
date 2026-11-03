//! Merge observed fork PCs into the pinned CLI's BCS coverage map.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use blast_launchpad_ptb_tests::{coverage::Hits, fork};
use move_binary_format::binary_config::BinaryConfig;
use move_binary_format::normalized::StringPool;
use move_binary_format::{CompiledModule, normalized};
use move_core_types::identifier::Identifier;
use move_coverage::coverage_map::CoverageMap;

fn read_files(directory: &Path, extension: &str) -> Result<Vec<PathBuf>> {
    let mut files = fs::read_dir(directory)?
        .map(|entry| Ok(entry?.path()))
        .collect::<Result<Vec<_>>>()?;
    files.retain(|path| path.extension().is_some_and(|ext| ext == extension));
    files.sort();
    Ok(files)
}

fn main() -> Result<()> {
    let [fork, package]: [PathBuf; 2] = std::env::args_os()
        .skip(1)
        .map(PathBuf::from)
        .collect::<Vec<_>>()
        .try_into()
        .map_err(|_| anyhow::anyhow!("usage: merge-fork-coverage TRACE_DIR MOVE_PACKAGE_DIR"))?;
    let marker = match package.file_name().and_then(|name| name.to_str()) {
        Some("presale") => "blast_presale",
        Some("migrators") => "blast_fun_migrators",
        _ => bail!("expected the presale or migrators package directory"),
    };
    let test_modules = read_files(
        &package.join("build").join(marker).join("bytecode_modules"),
        "mv",
    )?
    .into_iter()
    .map(|path| {
        let module = CompiledModule::deserialize_with_config(
            &fs::read(path)?,
            &BinaryConfig::new_unpublishable(),
        )?;
        Ok((module.self_id().name().to_string(), module))
    })
    .collect::<Result<BTreeMap<_, _>>>()?;

    let mut observed = Hits::new();
    for file in read_files(&fork.join("transactions"), "bcs")? {
        for (version, modules) in bcs::from_bytes::<Hits>(&fs::read(file)?)? {
            for (module, functions) in modules {
                let destination = observed
                    .entry(version)
                    .or_default()
                    .entry(module)
                    .or_default();
                for (function, pcs) in functions {
                    destination.entry(function).or_default().extend(pcs);
                }
            }
        }
    }

    for (venue, version) in [
        ("Cetus", fork::CETUS),
        ("Bluefin", fork::BLUEFIN),
        ("Aftermath DAO fee", fork::AFTERMATH_DAO_FEE),
        ("Aftermath AMM", fork::AFTERMATH_AMM),
    ] {
        let count: usize = observed
            .get(&fork::id(version))
            .into_iter()
            .flat_map(|modules| modules.values())
            .flat_map(|functions| functions.values())
            .map(BTreeSet::len)
            .sum();
        eprintln!("{venue} {version}: {count} unique venue instructions observed");
    }

    let path = package.join(".coverage_map.mvcov");
    let mut coverage = CoverageMap::from_binary_file(&path)?;
    // Each run replaces the old fork contribution, preserving the CLI unit-test runs.
    coverage.exec_maps.remove("venue-fork");
    let unit_marker = test_modules
        .get(marker)
        .context("missing unit marker module")?
        .self_id();
    let unit_identity = (*unit_marker.address(), unit_marker.name().to_owned());
    ensure!(
        coverage
            .exec_maps
            .values()
            .any(|run| run.module_maps.contains_key(&unit_identity)),
        "unit coverage does not match the current build; rerun sui move test --coverage after the fork",
    );
    let mut rejected = BTreeSet::new();
    let mut production = BTreeMap::new();
    let mut accepted = 0;
    for (version, modules) in observed {
        let published: BTreeMap<String, Vec<u8>> = bcs::from_bytes(&fs::read(
            fork.join("packages").join(format!("{version}.bcs")),
        )?)?;
        if !published.contains_key(marker) {
            continue;
        }
        for (name, bytes) in published {
            let mut runtime = CompiledModule::deserialize_with_defaults(&bytes)?;
            let unit = test_modules
                .get(&name)
                .context("published module missing from unit build")?;
            relocate(&mut runtime, unit)?;
            let mut pool = normalized::RcPool::new();
            let unit = normalized::Module::new(&mut pool, unit, true);
            let runtime = normalized::Module::new(&mut pool, &runtime, true);
            let module_name = Identifier::new(name.as_str())?;
            for key in runtime.functions.keys() {
                let body = unit.functions.get(key).context("missing unit function")?;
                let identity = (
                    *unit.address(),
                    module_name.clone(),
                    pool.as_ident_str(key).to_owned(),
                );
                production.insert(identity, body.code().len());
            }
            let Some(functions) = modules.get(&name) else {
                continue;
            };
            for (function, pcs) in functions {
                let key = pool.intern(move_core_types::identifier::IdentStr::new(&function)?);
                let runtime_body = runtime
                    .functions
                    .get(&key)
                    .context("missing runtime function")?;
                let unit_body = unit.functions.get(&key).context("missing unit function")?;
                if !runtime_body.equivalent(unit_body) || runtime_body.locals != unit_body.locals {
                    rejected.insert(format!("{name}::{function}"));
                    continue;
                }
                let function_name = Identifier::new(function.as_str())?;
                for pc in pcs {
                    ensure!(
                        usize::from(*pc) < unit_body.code().len(),
                        "invalid PC in {name}::{function}"
                    );
                    coverage.insert(
                        "venue-fork",
                        *unit.address(),
                        module_name.clone(),
                        function_name.clone(),
                        u64::from(*pc),
                    );
                    accepted += 1;
                }
            }
        }
    }
    ensure!(
        accepted > 0,
        "no compatible {marker} fork instructions found"
    );
    for function in rejected {
        eprintln!("Skipping {function}: unit and published function bytecode differ");
    }
    let unified = coverage.to_unified_exec_map();
    let mut covered = 0;
    let mut total = 0;
    for ((address, module, function), length) in production {
        let hits = unified
            .module_maps
            .get(&(address, module.clone()))
            .and_then(|entry| entry.get_function_coverage(function.as_ident_str()));
        let missing: Vec<_> = (0..length as u64)
            .filter(|pc| !hits.is_some_and(|hits| hits.contains_key(pc)))
            .collect();
        covered += length - missing.len();
        total += length;
        if !missing.is_empty() {
            eprintln!("{module}::{function} uncovered PCs: {missing:?}");
        }
    }
    eprintln!(
        "{marker} production instructions covered: {covered}/{total} ({:.2}%)",
        covered as f64 / total as f64 * 100.0
    );
    let temporary = path.with_extension("merged.tmp");
    fs::write(&temporary, bcs::to_bytes(&coverage)?)?;
    fs::rename(temporary, path)?;
    eprintln!("Merged {accepted} {marker} instruction observations from the fork");
    Ok(())
}

fn relocate(runtime: &mut CompiledModule, unit: &CompiledModule) -> Result<()> {
    let mut addresses = BTreeMap::from([(*runtime.self_id().address(), *unit.self_id().address())]);
    let unit_dependencies = unit.immediate_dependencies();
    for dependency in runtime.immediate_dependencies() {
        if unit_dependencies.contains(&dependency) {
            continue;
        }
        let mut matches = unit_dependencies
            .iter()
            .filter(|id| id.name() == dependency.name());
        let Some(target) = matches.next() else {
            continue;
        };
        ensure!(
            matches.next().is_none(),
            "ambiguous relocation for {dependency}"
        );
        if let Some(existing) = addresses.insert(*dependency.address(), *target.address()) {
            ensure!(
                existing == *target.address(),
                "conflicting relocation for {dependency}"
            );
        }
    }
    for address in &mut runtime.address_identifiers {
        if let Some(target) = addresses.get(address) {
            *address = *target;
        }
    }
    Ok(())
}
