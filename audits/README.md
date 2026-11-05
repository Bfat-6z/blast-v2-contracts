# Security audits

This directory preserves two reports, each tied to its reviewed source:

| Report | Reviewed revision | Coverage |
| --- | --- | --- |
| [Asymptotic - October 2026](blast-launchpad-asymptotic-oct-2026.pdf) | `01d76596` | External audit of the earlier launchpad |
| [Claude (Fable 5.1) - November 2026](blast-launch-stack-claude-nov-2026.pdf) | `4fe8d739` | AI security review of the shared launch stack; findings remediated in #217 |

The Claude report is an AI-conducted review. The seven packages of
[ADR 0137](../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md),
the templates and the vendors are a fresh lineage that still awaits its own
external audit and a quiet period before vault immutability (#195). The October
Asymptotic report covers the earlier launchpad at the revisions listed below.

Retain published reports when their reviewed code is superseded, and label their
scope and reviewed revisions. Boosts' review record is
[`docs/reviews/boosts-asymptotic-2026-10.md`](../docs/reviews/boosts-asymptotic-2026-10.md).

Add each new report here with its reviewed repository commits, scope, findings
and remediation status, and the SHA-256 of the original file.

## Asymptotic — Blast Launchpad, October 2026

[Download the complete report](blast-launchpad-asymptotic-oct-2026.pdf) (30 pages).
This is the supplied updated report, preserved without modification.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `commit-launchpad`.
- Review start: [`b549bb16e02e4c6e8ff59e1958435a638c784973`](https://github.com/interest-protocol/blast-v2-contracts/commit/b549bb16e02e4c6e8ff59e1958435a638c784973).
- Final reviewed commit, including remediation review: [`01d7659617abcd552cece6d05b9db409ec4ff2c0`](https://github.com/interest-protocol/blast-v2-contracts/commit/01d7659617abcd552cece6d05b9db409ec4ff2c0).

### Scope

The report covers only `blast_fun` in `sui/launchpad`: the launch lifecycle and
bonding curve, fee custody and claims, creator authority, configuration, package
administration, and migration handoff.

Presale, Blast SUI, Boosts, migrators, and the generated-coin template are outside
the review. `blast_admin`, `blast_partners`, and `blast_fun_timelock` are treated
as trusted dependencies. Migration adapters, receiving DEX venues, and off-chain
services are also outside scope. See the report's Scope and Coverage and
Limitations sections for the full boundaries.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 5 low, and 5 informational**
findings. L-1, L-2, L-5, and I-1 through I-5 are **remediated**. L-3 and L-4,
concerning upgrade and root administrator custody, are **acknowledged**.
These statuses are the auditor's assessment at the final reviewed commit.

This report is retained as the historical external audit of those revisions.
The launchpad has since been rewritten as part of the shared launch stack;
this report does not establish audit coverage of the current stack or a later
deployment. Compare later source with the reviewed commit before relying on
its findings.

### File integrity

SHA-256 of the original PDF:

```text
09d627f8c5e58374ed28f1e1237a8472e3749b19c259fc3da82635e731e7801b
```

## Claude (Fable 5.1) — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-claude-nov-2026.pdf) (27 pages).
A deep adversarial security review conducted by Claude (Fable 5.1), Anthropic's
model, in an agentic review session for Interest Protocol, written in the format
of the Asymptotic report above. The system map, the function inventory and the
checked-and-holding record are its appendices.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`4fe8d739f04bafd0775691795eb9f3727e984089`](https://github.com/interest-protocol/blast-v2-contracts/commit/4fe8d739f04bafd0775691795eb9f3727e984089) (#212).
- Remediation reviewed at [#217](https://github.com/interest-protocol/blast-v2-contracts/pull/217)
  (`claude/deep-audit-fixes`, rebased on `main` at `88951fe9`).

### Scope

`blast_admin`, `blast_core`, `blast_vault`, `blast_fun`, `blast_presale` and
`blast_migrators`, the seams between them, and the fidelity of the Cetus and Bluefin
interface stubs against mainnet bytecode. `blast_partners`, the generated coin
packages, the vesting package, the Sui Framework and the Move Standard Library are
trusted dependencies. The review tests; it does not prove. No venue bytecode ran in
it; the PTB fork gate remains the evidence for venue behaviour.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 1 low, and 4 informational**
findings and one hypothesis (H-1, whether Bluefin's auto-LP add can ask more than
the venue's local estimate). All five findings are **remediated** in #217 (ADR 0134,
amendment of 5 November 2026): the vault's `unpause` is version-gated (L-1); every
`unpause` requires the core treasury's notice guarded (I-1);
`MigrationAllocationPaid` carries the vesting schedule IDs (I-2); holder-reward
leaves are documented as account addresses (I-3); auto-LP compounding is the
venues' own `compound_auto_lp`, apart from collection (I-4). H-1 can no longer
block collection, and the launchpad fork gate exercises the add on both venues
after each collection; adversarial pool states are
[#218](https://github.com/interest-protocol/blast-v2-contracts/issues/218).

The proof-of-concept tests and run logs behind the report are held by Blast beside
the report's source, not in this repository.

### File integrity

SHA-256 of the PDF:

```text
f42835edd92decf8501f6d240134a81e96c1d1d93fb365fb54ffcc830a709535
```
