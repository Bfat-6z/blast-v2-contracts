# Sui Move workspace

This directory contains independently deployed or dependency-isolated Move
packages. Build and verify from the directory containing the target
`Move.toml`; use that package's scripts when present.

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
