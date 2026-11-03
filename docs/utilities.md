# Immutable utility contracts

OTC and vesting are maintained in `blast-v2-contracts`, alongside
[`sdk/`](../sdk/README.md), the unchanged `@interest-protocol/blast-util-sdk`
package for OTC and vesting. Each Move package remains independently deployed
and imports only the Sui framework. Consolidation changes no package ID, ABI,
SDK import name, or on-chain state.

- [OTC](../sui/otc/README.md): fixed-rate coin offers.
- [Vesting](../sui/vesting/README.md): stepped-linear and checkpoint schedules.

Both packages are immutable on mainnet. Their `Published.toml` files
identify the deployed packages. The original deployment records preserve the
publication and `make_immutable` transactions:

- [OTC and vesting](../deployments/sui/mainnet/2026-09-24-otc-and-vesting.json).

### Retired timelock

The immutable `blast_fun_timelock` package stays published on mainnet, but its source
left this repository on 2026-11-03 once no Blast package depended on it; Blast's
delayed administration uses `blast_admin`'s delayed modules. Its records remain:
[canonical](../deployments/sui/mainnet/2026-09-26-timelock-unbounded-delay.json) and
[superseded](../deployments/sui/mainnet/2026-09-26-timelock.json) (ten-year maximum delay).
Its source is at commit `96e9d25` and the archival tag below.

## Move dependencies

Packages in this repository use local paths. External consumers can pin the
history-preserving import commit, which contains all three packages and their
publication metadata:

```toml
[dependencies]
blast_fun_otc = { git = "https://github.com/interest-protocol/blast-v2-contracts.git", subdir = "sui/otc", rev = "c72846e69e552f523b0fee110ff713de605081a5" }
blast_fun_vesting = { git = "https://github.com/interest-protocol/blast-v2-contracts.git", subdir = "sui/vesting", rev = "c72846e69e552f523b0fee110ff713de605081a5" }
```

Build for mainnet so Sui resolves `Published.toml` to the existing immutable
packages. Existing consumers pinned to utility commit
`63b6cf86c0e1a74f699610fe182b1de8d8789a14` can change just the repository URL:
that commit is preserved in this repository's imported history. The old repository has been removed; its URLs no longer resolve.

## Published-source verification

Later style changes moved source lines used by `#[error]` abort codes. Current
source therefore must not be presented as byte-for-byte publication source.
The original commits are retained: use `e1a7c62` for OTC and vesting, and
`96e9d25` for timelock. Create a separate checkout at the relevant commit and
run `sui client verify-source sui/otc`, `sui client verify-source sui/vesting`,
or, for the retired timelock, `sui client verify-source sui/timelock` there with Sui CLI `1.77.2`.
Historical records use the current repository URL for retrieval and retain the
original repository name in `original_repository`. Commit IDs, source hashes,
publication identities and working-tree qualifications are unchanged. The original
September 26 timelock publication commit is also retained under the archival tag
[`archive/utility-timelock-2026-09-26`](https://github.com/interest-protocol/blast-v2-contracts/tree/archive/utility-timelock-2026-09-26).

For an older checkout that still pins the removed Git remote, change its dependency
URL to this repository while retaining the exact revision. To preserve a shared
checkout's files, Git can redirect that exact old repository prefix instead:

```sh
git config --global --add url.https://github.com/interest-protocol/blast-v2-contracts.insteadOf https://github.com/interest-protocol/blast-util-contracts
```

This is a local compatibility setting for retained branches; new manifests must
use the consolidated repository or same-repository local paths.

## Development and licensing

Run `sui move test --path sui/<package>` and that package's
`scripts/check_coverage.sh`. The SDK's check scripts are in
[`sdk/package.json`](../sdk/package.json). No deployment is part of repository
consolidation.

The imported packages, SDK, documentation, vectors, and release records remain
MIT-licensed. Each package and the SDK carry the original license notice.
[ADR 0135](decisions/0135-utility-contracts-consolidation.md) records the move
and the exact imported paths.
