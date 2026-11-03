# Blast migration adapters

This aggregate package starts every launch at the creator's venue tier,
completes the launchpad's linear migration handoff into supported venue
positions, keeps the LP principal and the protocol migration residuals in each
launch's sealed `LpVault`, and owns everything after migration: the LP-fee
policy, collection, auto-LP, holder rewards, and fee-split updates (ADR 0089). Venue code depends inward on the launchpad; the launchpad never
imports this package.

Use task-specific sources instead of a duplicated route, event, dependency, or
error inventory:

- [accepted migrator ADRs](../../docs/decisions/README.md) for durable design;
- [DEPENDENCIES.md](DEPENDENCIES.md) for venue package identities, pinned ABI
  evidence, and the mainnet inspection matrix;
- `scripts/check_mainnet_abi.mjs` for live compatibility;
- [release gates](../../docs/testing.md) for repository-wide evidence.

Administration is not implemented here. This package takes the Launchpad's role
types from `blast_fun_domain` on the singleton Blast ACL and declares none of its
own. It does own an independent operational generation and its own sealed
`PackageAdmin`, so advancing this package leaves Launchpad on its generation.

Publication transfers an owned Publication holding the Publisher and initial
generation. `package_admin::wrap` consumes it with the matching fresh UpgradeCap
and shares the version. Publication-owned fee policies start at zero notice.
Upgrade custody starts at 48 hours.
Configure the initial LP-fee destination and default shares through ordinary ACL schedule/apply calls
with Clock. Settle all setup proposals, enable each operation’s intended
self-timelocked notice, and verify it before releasing launchpad migration. Later policy changes use
that operation's applied delay. Migrators has no separate pause switch (ADR 0134).

Every protected mutation checks **this** package's generation. The Launchpad
generation is no longer treated as this package's own: a composed call that
migrates a launch supplies both version objects, because each package checks
only the transitions it implements.

## LP fees after migration

Anyone can call a venue's `collect_fees`. In one transaction it collects the
position's fees, pays Blast's live share for that coin to the protocol
destination, and splits the rest by the launch's `FeeSplit`:

| Part | Where it goes |
| --- | --- |
| Creator | accrues in the vault; `vault::claim_creator_fees` pays it to the holder of the launch's live `CurveFeeCap` |
| Auto-LP | added back at the pool's current price (Cetus: to a second position, because the migration position is burned through Cetus LP Burn; Bluefin: to the migration position); what the pool does not take waits for the next call |
| Rewards | accrues in the vault for holder-reward rounds |
| Burn | the Meme is burned at once (paid to `@0x0` when the supply is fixed); the Quote waits for a buyback |
| Recipients | paid directly to each address |

A Blast administrator with the buyback role calls the venue's `buyback_and_burn`
with an amount of the waiting burn Quote and a minimum Meme out set from an
off-chain price: it swaps that much burn Quote for Meme in the vault's pool and
burns it. The swap is not permissionless,
because anyone could move the pool's price around it (ADR 0091).

Cetus orders a pool's coins by type name, so its `migrate`, `collect_fees`,
`settle_and_apply_fee_split`, and `buyback_and_burn` take the pool's coins in
that order as two extra type arguments, `<Meme, Quote, CoinA, CoinB>`, and
reject any other pair (ADR 0100). Bluefin's routes take `<Meme, Quote>`.

`FeesCollected`, `AutoLiquidityAdded`, and `BuybackBurned` break down every amount
for indexers.
The live curve-fee cap holder schedules or cancels a split with
`vault::schedule_fee_split` / `vault::cancel_fee_split`. The initial notice is
48 hours. Expiry leaves the old split active until anyone calls the venue's
`settle_and_apply_fee_split`, settling accrued fees under the old split before
activating the stored replacement and next notice. Delay reductions still wait
the old notice; replacement restarts that wait. An administrator
changes Blast's default or per-coin share in `LpFeePolicy`, from the next
collection. Because auto-LP adds at the current price, a caller can move the
price around a collection and skim part of that call's auto-LP amount; frequent
collection keeps each slice small (ADR 0089).

## Holder rewards

Blast's off-chain system turns checkpointed holder balances into a Merkle
allocation. A Blast administrator schedules it with
`blast_holder_rewards::schedule_round` on the vault's delayed round-publication
slot. Once the vault's round notice (zero by default) has elapsed, anyone calls
`blast_holder_rewards::publish_round`, which re-checks the terms, reserves the
round's budget from the vault's rewards balance into a shared `Round`, and opens
claims for the scheduled window. `CancelAdmin` can cancel a scheduled round,
which reserved nothing. Anyone can relay a proof, and each leaf pays its
committed beneficiary once before the round's claim deadline.
An optional Quote gas reserve is funded separately, with its treasury bound to
the governed LP-fee destination at publication. `RewardsAdmin` may settle a capped
reimbursement once; unused reserve returns to the vault. Anyone may close at the
deadline to return unclaimed rewards and unsettled gas custody. Published
checkpoint intervals may have gaps but must not overlap.

**The administrator can assign unallocated rewards to any recipient in a new
round.** Merkle proofs enforce the published allocation, not the truth of the
off-chain holder accounting, so schedule from a multisig with independent
accounting review, and raise the round notice so a compromised administrator's
round can be cancelled before anyone publishes it. Each round reserves its full declared budget and keeps a
claim bitmap until closure. The administrator cannot rewrite a root or
cancel its holder claims before the deadline; permissionless close recovers
remaining custody at the deadline. The leaf commits the vault ID, the round number, the index, the
beneficiary, and both amounts (`docs/vectors/holder-rewards.json` is the fixed
Move/SDK commitment vector).

The default accounting policy weights direct address balances by milliseconds
held between checkpoints. It excludes configured custody addresses and the zero
address. LP positions and balances held inside other contracts are not
beneficial-owner balances under this policy.

Move source and tests own current functions, events, errors, and custody behavior.
`Move.toml` and `Move.lock` own dependency resolution.
