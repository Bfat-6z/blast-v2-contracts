# Sui Move workspace

## Find a package

| If you’re looking for | Start here |
| --- | --- |
| Bonding-curve launches or overflow presales | [Launchpad](launchpad/) · [Presale](presale/) |
| Shared launch logic, partner fees, or liquidity after migration | [Core](core/) · [Partners](partners/) · [LP vault](vault/) |
| DEX integrations or a partner-specific venue | [Migrators (Cetus and Bluefin)](migrators/) · [Vendor contracts](vendors/) |
| Access control, package versions, or upgrade custody | [Admin](admin/) · [Delayed UpgradeCap manager](upgrade_cap_manager/) |
| Liquid staking or leveraged coins | [Blast SUI](blast_sui/) · [Boosts](boosts/) |
| A coin template | [Standalone coin](coin_template/) · [Launch ticket](launch_ticket_template/) · [Presale coin](presale_coin_template/) |
| Standalone immutable utilities | [OTC](otc/) · [Vesting](vesting/) · [Utility integration guide](../docs/utilities.md) |
| Test assets for presale | [Presale testkit](presale_testkit/) |

## Find source, tests, and deployment records

- For implementation, open `sources/` in the package directory. For examples
  and behavior checks, look in `tests/` and any `ptb_tests/` directory.
- Build and verify from the directory containing the target `Move.toml`. Use
  that package’s scripts when present. For Boosts and vendor contracts, open
  the individual package first.
- For package IDs, custody, and publish order, see the
  [deployment records](../deployments/README.md). For public functions, types,
  events, and abort codes, see the [integrator references](../llms/).

## Package layout and boundaries

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
See the repository [architecture](../docs/architecture.md) and
[decision index](../docs/decisions/README.md) for the durable boundaries.
