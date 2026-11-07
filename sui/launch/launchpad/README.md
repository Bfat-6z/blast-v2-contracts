# Blast launchpad

This package owns the Blast launch lifecycle, custody, configuration, fees,
creator authority, and venue-neutral migration handoff. It imports no venue
package; adapters compose with it through a programmable transaction block.

Administration is not implemented here. `blast_admin` owns the singleton Blast
ACL and the generic `package_version::PackageVersion<BLAST_FUN>` and
`package_admin::PackageAdmin<BLAST_FUN>`, with their package-scoped
`UpgradeAdmin`, `PauseAdmin`, `UnpauseAdmin` and `CancelAdmin` roles; product
roles are `blast_core::blast_domain`'s
([ADR 0097](../../../docs/decisions/0097-one-singleton-acl-with-typed-roles.md)).
This package's one-time-witness module owns `PackageWitness`, the one witness it pins at
publication and passes to every sealed call, and `launch_config::unpause`
releases pause bits once every launchpad notice is guarded. Blast's fees go to `blast_core::blast_treasury::Treasury` through the
core protocol-fee ledger each launch holds.

A governed upgrade is one transaction: authorize the digest, run the native
Upgrade command, then call `blast_admin::package_admin::commit_upgrade_and_advance`,
which commits the receipt to the same sealed cap and advances the operational
version. There is no separate activation step.

Use these sources instead of a duplicated module inventory:

- [deployment procedure](DEPLOYING.md) for mandatory capability wrapping and
  custody verification before launch activity;
- [architecture](../../../docs/architecture.md) for package and SDK boundaries;
- [decision index](../../../docs/decisions/README.md) for accepted protocol rules;
- [test vectors](../../../docs/vectors/README.md) and
  [release gates](../../../docs/testing.md) for verification;
- [Launch ticket template](../../templates/launch_ticket_template/) for generated-coin publication.

Move source and tests are authoritative for the current ABI, storage, events,
errors, and behavior; `sources/lib/errors.move` is the sole error registry.
`Move.toml` and `Move.lock` are authoritative for the
toolchain environments and dependency graph.
