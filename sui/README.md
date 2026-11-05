# Sui Move workspace

This directory contains independently deployed or dependency-isolated Move
packages. Build and verify from the directory containing the target
`Move.toml`; use that package's scripts when present.

Within a package, group related modules by responsibility and keep the layout
shallow. Launch construction, configuration, accounting, pure math, package
administration, and venue implementations each have their own directory when
there are several related modules. Package entry points stay visible at the
source root; `lib/` holds package-wide constants, errors, and event plumbing.
Related tests follow the same groups under `tests/`. Small packages can stay
flat rather than adding a directory for every file.

These directories help readers navigate; Move still identifies a module by
its declared address and name. A directory does not create a namespace,
visibility boundary, or independently deployable component. Keep state and
the operations protecting its invariants together, and add a package only for
a real deployment, authority, or dependency boundary.

Core packages do not import venue adapters. Adapters depend inward on the
smallest required core surface. In the launch stack the products (`launchpad`,
`presale`) and the venues (`migrators`, `vendors/*`) never import each other:
they depend inward on `core`, the shared venues also on `vault`, and they meet
only through `blast_core` values passed in the transaction (ADR 0137).
[`deployments/README.md`](../deployments/README.md) gives the publish order.
See the repository [architecture](../docs/architecture.md) and
[decision index](../docs/decisions/README.md) for the durable boundaries.

One-off partner packages live under [`vendors/`](vendors/README.md), one
directory per contract.

Immutable utilities live in [`otc/`](otc/README.md) and
[`vesting/`](vesting/README.md).
Their source, deployment provenance, and SDK are maintained here; see the
[utility integration guide](../docs/utilities.md).
