# Blast migration venues

This package holds the launchpad's Cetus and Bluefin venues. A venue takes part
in a launch twice. In the launch's creation PTB its `prepare` borrows the coin's
`TreasuryCap`, records the pool tier (Cetus also reserves pool creation), and
returns a sealed `blast_core::migration::VenueTicket` that `launch::new` redeems
and checks against `LaunchConfig`'s venue allowlist. At migration the venue
redeems the sealed `Migration` that `launch::migrate` returns, creates the pool,
and creates and shares the launch's `blast_vault::vault::Vault` in the same
call. The vault, not this package, holds the position, the fee split, Blast's
share, the partner hold, holder rewards, and the owner's balances
([ADR 0137](../../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)).
The venues depend inward on the launchpad, `blast_core`, and `blast_vault`;
none of them imports this package.

Use task-specific sources instead of a duplicated route, event, dependency, or
error inventory:

- [accepted migrator ADRs](../../docs/decisions/README.md) for durable design;
- the venues and vault guides under [`docs/llms/`](../../docs/llms/) for calls
  and their objects;
- [DEPENDENCIES.md](DEPENDENCIES.md) for venue package identities, pinned ABI
  evidence, and the mainnet inspection matrix;
- `scripts/check_mainnet_abi.mjs` for live compatibility;
- [release gates](../../docs/testing.md) for repository-wide evidence.

Administration is not implemented here. Package upgrades take the launchpad's
`blast_fun_domain` roles on the singleton Blast ACL, and buybacks take the
shared `blast_core::blast_domain::BuybackAdmin`; the package declares no roles
of its own. It does own an independent operational generation and its own
sealed `PackageAdmin`, so advancing this package leaves the launchpad and the
vault on their generations. Every venue call checks **this** package's
generation; a call that also mutates the launchpad or the vault takes that
package's version object too, because each package checks only the transitions
it implements.

Publication transfers an owned Publication holding the Publisher and initial
generation. `package_admin::wrap` consumes it with the matching fresh UpgradeCap
and shares the version; upgrade custody starts with a 48-hour notice. The
package has no pause switch: migration stops with the launchpad's Migrate bit,
and buybacks with the vault's admin pause bit (ADR 0134).

## LP fees after migration

Anyone can call a venue's `collect_fees`. In one transaction it collects the
position's fees and hands them to `blast_vault::vault::split_fees`, which pays
Blast's share of each asset to the core `Treasury` (or holds it for the
launch's partner) and splits the rest by the vault's `FeeSplit`:

| Route | Where it goes |
| --- | --- |
| Owner | accrues in the vault; the holder of the launch's live `CurveFeeCap` claims it with `launch::prove_owner` and `blast_vault::vault::claim_owner_balances` |
| Auto-LP | added back at the pool's current price (Cetus: to a second position, because the migration position is burned through Cetus LP Burn; Bluefin: to the migration position); what the pool does not take waits for the next call |
| Holder rewards | accrues in the vault for holder-reward rounds |
| Burn | the Meme is burned at once (paid to `@0x0` when the supply is fixed); the Quote waits for a buyback |
| Address | paid directly to each address |

A Blast administrator with `BuybackAdmin` calls the venue's `buyback_and_burn`
with an amount of the waiting burn Quote and a minimum Meme out set from an
off-chain price: it swaps that much burn Quote for Meme in the vault's pool and
burns it. The swap is not permissionless, because anyone could move the pool's
price around it (ADR 0091).

Cetus orders a pool's coins by type name, so its `migrate`, `collect_fees`,
`settle_and_apply_fee_split`, and `buyback_and_burn` take the pool's coins in
that order as two extra type arguments, `<Meme, Quote, CoinA, CoinB>`, and
reject any other pair (ADR 0100). Bluefin's routes take `<Meme, Quote>`.

The owner schedules or cancels a new split on the vault with an owner proof
(`blast_vault::vault::schedule_fee_split` / `cancel_fee_split`); the notice is a
fixed 48 hours. Expiry leaves the old split active until anyone calls the
venue's `settle_and_apply_fee_split`, which settles accrued fees under the old
split before activating the stored replacement. Blast's share starts from
`LaunchConfig`'s delayed `ProtocolLpFees` at migration, is capped at 30% per
asset, and changes only per vault after the vault's fixed 48-hour notice.
Because auto-LP adds at the current price, a caller can move the price around a
collection and skim part of that call's auto-LP amount; frequent collection
keeps each slice small (ADR 0089).

## Holder rewards

Holder-reward rounds belong to the vault (`blast_vault::holder_rewards`), under
the shared `blast_core::blast_domain::RewardsAdmin`; this package only routes
the holder-reward share into the vault. **The rewards administrator can assign
unallocated rewards to any recipient in a new round.** Merkle proofs enforce the
published allocation, not the truth of the off-chain holder accounting, so
schedule from a multisig with independent accounting review; the round notice
lets `CancelAdmin` cancel a compromised administrator's round before anyone
publishes it.

The default accounting policy weights direct address balances by milliseconds
held between checkpoints. It excludes configured custody addresses and the zero
address. LP positions and balances held inside other contracts are not
beneficial-owner balances under this policy.

Move source and tests own current functions, events, errors, and custody behavior.
`Move.toml` and `Move.lock` own dependency resolution.
