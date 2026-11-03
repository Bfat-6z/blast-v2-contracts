#!/usr/bin/env python3
"""Run Cargo with the pinned Move VM tracer fix in an isolated build manifest."""

import fcntl
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib


def cargo(*args, **kwargs):
    return subprocess.run(("cargo", *args), check=True, **kwargs)


def prepare(crate, overlay):
    host = next(
        line.removeprefix("host: ")
        for line in subprocess.check_output(("rustc", "-vV"), text=True).splitlines()
        if line.startswith("host: ")
    )
    metadata = json.loads(cargo(
        "metadata", "--locked", "--features", "fork-coverage",
        "--format-version", "1", "--filter-platform", host,
        cwd=crate, stdout=subprocess.PIPE,
    ).stdout)
    runtime = next(pkg for pkg in metadata["packages"] if pkg["name"] == "move-vm-runtime")
    source = Path(runtime["manifest_path"]).parent
    git, rev = runtime["source"].removeprefix("git+").split("?rev=")
    rev, actual = rev.split("#")
    if rev != actual:
        raise ValueError("expected an exact Move VM revision")
    workspace_manifest = (source.parent.parent / "Cargo.toml").read_text()
    dependencies = tomllib.loads(workspace_manifest)["workspace"]["dependencies"]

    def dependency_line(name):
        spec = dependencies[name]
        if isinstance(spec, dict) and "path" in spec:
            return f'{name} = {{ git = "{git}", rev = "{rev}" }}'
        return re.search(rf"(?m)^{re.escape(name)}\s*=\s*[^\n]+", workspace_manifest)[0]

    runtime_manifest = (source / "Cargo.toml").read_text()
    runtime_manifest = re.sub(
        r"\[dev-dependencies\].*?(?=\n\[)", "", runtime_manifest, flags=re.S,
    )
    runtime_manifest = re.sub(
        r"(?m)^(\S+)\.workspace = true$", lambda match: dependency_line(match[1]),
        runtime_manifest,
    )
    runtime_manifest = re.sub(
        r"(?m)^move-bytecode-verifier = .*$", dependency_line("move-bytecode-verifier"),
        runtime_manifest,
    )

    patched = overlay / "runtime"
    patch_file = crate / "fork/move-vm-tracer.patch"
    # Preserve source timestamps across the test and report invocations.
    stamp = patched / ".patch"
    patch_identity = runtime_manifest.encode() + b"\n" + patch_file.read_bytes()
    if not stamp.exists() or stamp.read_bytes() != patch_identity:
        if patched.exists():
            shutil.rmtree(patched)
        shutil.copytree(source / "src", patched / "src")
        subprocess.run(("patch", "--batch", "--fuzz=0", "-p0", "-i", patch_file), cwd=patched, check=True)
        (patched / "Cargo.toml").write_text(runtime_manifest)
        stamp.write_bytes(patch_identity)

    for name in ("src", "tests", "fixture", "fork", "target"):
        path = overlay / name
        if not path.is_symlink():
            path.symlink_to(crate / name, target_is_directory=True)
    manifest = (crate / "Cargo.toml").read_text()
    lock = (crate / "Cargo.lock").read_text()
    # Keep the original dependency graph pinned. Only the VM's source changes.
    lock, replacements = re.subn(
        r'(name = "move-vm-runtime"\nversion = "[^"]+"\n)source = "[^"]+"\n',
        r"\1", lock,
    )
    if replacements != 1:
        raise ValueError("expected one git-sourced Move VM runtime in Cargo.lock")
    for name, contents in (("Cargo.toml", manifest), ("Cargo.lock", lock)):
        path = overlay / name
        if not path.exists() or path.read_text() != contents:
            path.write_text(contents)
    return f'patch."{git}".move-vm-runtime.path="runtime"'


if __name__ == "__main__":
    crate = Path(__file__).resolve().parents[1]
    overlay = crate / "target/fork-coverage-build"
    overlay.mkdir(parents=True, exist_ok=True)
    with (overlay / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        patch = prepare(crate, overlay)
        cargo("--config", patch, "--config", 'env.BLAST_MOVE_VM_TRACER_PATCHED="1"',
              *sys.argv[1:], cwd=overlay)
