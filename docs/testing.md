# Release verification

The vendored Sui Move testing skill owns generic test design and local quality
practice. This document owns only Blast-specific cross-package and release
evidence.

## Package gates

Run every applicable verification script in the package being changed. Where a
package has no wrapper, run the pinned toolchain's build, warning-as-error lint,
tests, and source-boundary check directly from that package. Generated traces
and coverage artifacts are not committed.

Run `python3 scripts/check_move_errors.py` for the first-party error gate. Each
error must be used in production, numbered sequentially from zero within its
module, and covered by an exact abort code and raising-module assertion. Registry
macros also need literal numeric pins. The gate checks Move test declarations and
the explicitly mapped native venue oracles; run those suites to verify behavior.
Aftermath pool postconditions have direct guard tests because local interface
stubs abort before migration can reach them; these do not replace the external
venue gate below.

For ADR 0134 fresh-stack checks, run `bash scripts/test_admin_delay.sh` under the
workspace memory guard. It temporarily excludes historical first-party publication
metadata and supplies synthetic genesis destinations and native-cap identities,
then restores the manifests, publications and lockfiles on exit. It never connects
to a database or chain. Run the source gates in that same fresh-stack environment
with `bash scripts/test_admin_delay.sh --boundaries-only admin launchpad presale migrators`.
Run these wrappers sequentially: they temporarily edit the same manifests and
publication metadata. The Rust PTB harness also supplies a nonzero genesis
recipient while compiling and restores each manifest afterward. Its initial
configuration wraps Publication, then uses ordinary real-ACL schedule/apply calls
at zero delay. It enables independent 48-hour operation notices before the immediate real-ACL unpause
without advancing Clock. Later governed changes schedule, advance the simulator
by the snapshotted delay, and apply through public entry points. Policy tests also
prove old-delay updates, same-PTB ordering/rollback and unauthorized rejection.

Run the pause matrices from `sui/launchpad/ptb_tests`, under the same memory guard:

```bash
cargo test --locked --test atomic_migration pause_ -- --test-threads=1
cargo test --locked --test presale_venue_fork presale_pause_ -- --test-threads=1
```

Both exercise every reachable pause state and every `u8` input for both mutators,
including stored-generation mismatch, exact events and rollback. Real ACL tests
cover role separation, wrong witness types, role and administrator revocation,
and successful and failing multi-command sequences. The presale matrix also
preserves a funded sale's balances, currency and capability. Each package's Move
`pause_tests` directly covers the package-only operation guard: every supported
state/query pair, every disjoint `u8` query, and unsupported query bits combined
with paused operations. The administration source gate pins every protected
operation's version/pause guard order and keeps settlement and exits available.

Measure instruction coverage of the three pause functions independently of the
larger suites with the fresh-stack wrapper:

```bash
MOVE_TEST_FILTER=pause_tests bash scripts/test_admin_delay.sh --coverage launchpad presale
```

Require 100% for `pause`, `unpause` and `assert_not_paused` in both package markers.
Run the full affected suites separately without the filter.

Native PTB fixture output stays under the test crate's ignored `target/ptb-fixtures/`
directory, so checkouts can share Cargo's compiler cache without overwriting each
other's simulator artifacts.

## Protocol vectors

The chain-neutral vectors under [`vectors/`](vectors/) are the numerical
compatibility boundary for curve quotes, fees, graduation, quote decimals,
and creator attestations. Regenerate vectors from the formula that
owns them; do not hand-edit expected results. An unexplained difference is a
release blocker.

## External venue gate

The migrators package contains local interface stubs, so a local build proves
type compatibility only. Before release:

1. Run its offline ABI self-test and live mainnet ABI check.
2. Run the replacement Cetus and Bluefin dev-inspect matrix in
   [`sui/migrators/DEPENDENCIES.md`](../sui/migrators/DEPENDENCIES.md).
3. Record the reviewed venue revisions, module fingerprints, normalized ABI,
   route results, residual bounds, and fee-collection results.
4. Describe LP custody using the current upgrade state. While upgradeable,
   the package has no exposed principal withdrawal path but can still change
   through a delayed upgrade. Scheduling immutability does not freeze the
   package until that action executes (ADR 0134).

## Blast SUI gate

Run the complete `sui/blast_sui/scripts/verify.sh` gate. Publishing and
upgrading additionally follow the package's
[deployment](../sui/blast_sui/DEPLOYING.md) or
[upgrade](../sui/blast_sui/UPGRADING.md) runbook.

## Evidence

Store normalized public evidence under `deployments/<chain>/<network>/` using
[`deployments/README.md`](../deployments/README.md). A passing statement must
name the exact command or live check, its target revision/environment, and its
result. Console output alone is not a release record.
