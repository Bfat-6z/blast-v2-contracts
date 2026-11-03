# Immutable utility contracts

OTC, vesting, and timelock are maintained in `blast-v2-contracts`, alongside
[`sdk/`](../sdk/README.md), the unchanged `@interest-protocol/blast-util-sdk`
package for OTC and vesting. Each Move package remains independently deployed
and imports only the Sui framework. Consolidation changes no package ID, ABI,
SDK import name, or on-chain state.

- [OTC](../sui/otc/README.md): fixed-rate coin offers.
- [Vesting](../sui/vesting/README.md): stepped-linear and checkpoint schedules.
- [Timelock](../sui/timelock/README.md): custody until a positive delay expires.

All three packages are immutable on mainnet. Their `Published.toml` files
identify the deployed packages. The original deployment records preserve the
publication and `make_immutable` transactions:

- [OTC and vesting](../deployments/sui/mainnet/2026-09-24-otc-and-vesting.json).
- [Canonical timelock](../deployments/sui/mainnet/2026-09-26-timelock-unbounded-delay.json).
- [Superseded timelock](../deployments/sui/mainnet/2026-09-26-timelock.json): its
ten-year maximum delay was removed in the canonical package. Use the canonical
package's `Published.toml` for new integrations.

## Move dependencies

Packages in this repository use local paths. External consumers can pin the
history-preserving import commit, which contains all three packages and their
publication metadata:

```toml
[dependencies]
blast_fun_otc = { git = "https://github.com/interest-protocol/blast-v2-contracts.git", subdir = "sui/otc", rev = "c72846e69e552f523b0fee110ff713de605081a5" }
blast_fun_vesting = { git = "https://github.com/interest-protocol/blast-v2-contracts.git", subdir = "sui/vesting", rev = "c72846e69e552f523b0fee110ff713de605081a5" }
blast_fun_timelock = { git = "https://github.com/interest-protocol/blast-v2-contracts.git", subdir = "sui/timelock", rev = "c72846e69e552f523b0fee110ff713de605081a5" }
```

Build for mainnet so Sui resolves `Published.toml` to the existing immutable
packages. Existing consumers pinned to utility commit
`63b6cf86c0e1a74f699610fe182b1de8d8789a14` can change just the repository URL:
that commit is preserved in this repository's imported history.

## Published-source verification

Later style changes moved source lines used by `#[error]` abort codes. Current
source therefore must not be presented as byte-for-byte publication source.
The original commits are retained: use `e1a7c62` for OTC and vesting, and
`96e9d25` for timelock. Create a separate checkout at the relevant commit and
run `sui client verify-source sui/otc`, `sui client verify-source sui/vesting`,
or `sui client verify-source sui/timelock` there with Sui CLI `1.77.2`.
Historical records keep their original repository URL as provenance.

## Development and licensing

Run `sui move test --path sui/<package>` and that package's
`scripts/check_coverage.sh`. The SDK's check scripts are in
[`sdk/package.json`](../sdk/package.json). No deployment is part of repository
consolidation.

The imported packages, SDK, documentation, vectors, and release records remain
MIT-licensed. Each package and the SDK carry the original license notice.
[ADR 0135](decisions/0135-utility-contracts-consolidation.md) records the move
and the exact imported paths.
