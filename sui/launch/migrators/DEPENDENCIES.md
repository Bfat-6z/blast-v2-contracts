# Migrator dependencies and release gates

This is the reproducible package-id and dependency matrix for the one aggregate
`blast_migrators` package. It records what the venues link to, how that is
re-verified against mainnet, and which gates must pass before release.

## Package boundary

Cetus and Bluefin are the only venues (ADR 0088), as modules in one
independently deployed package that serves both products. No product imports
this package and this package imports no product; each venue module depends
inward on `blast_core` and `blast_vault`, owns one sealed `Venue() has drop`
witness, and, in the same PTB as the product's own `migrate`, redeems the
`Migration` it returned and locks the position in a new
`blast_vault::vault::Vault` (ADR 0137). Aftermath, MMT, and Turbos were removed
before publication together with their witnesses, local interfaces, and
dependency pins; Aftermath remains only in the one-off DAO vendor, a separate
venue package over `blast_core` that creates no vault.

- **Release venue matrix.** A venue reaches a sale only through its own
  witness: `prepare` issues the `blast_core::migration::VenueTicket` that the
  product's `new` redeems, and `migrate` redeems the sealed `Migration` that the
  product's `migrate` returned earlier in the PTB. The matrix is therefore exactly `cetus::Venue` and
  `bluefin::Venue`, each completing into `blast_vault` custody.
  `scripts/check_source_boundaries.sh` pins the package's exact module set and
  every module's public and package function set, so any added module or
  non-private function fails it until the gate is extended, and no module
  declares an `entry` function. Within that set it fails when any module other
  than `cetus` and `bluefin` declares a venue witness or reaches the hand-off
  seams, when a migration does not create and share a vault from the redeemed
  terms, or when a local venue interface other than Cetus's exists. A future
  venue is separate work: it first defines and tests its tier validation, its
  preparation, its atomic migration into the vault, collection, settled split
  update, and event conformance, and then extends that gate. There is no
  generic plug-in constructor.
- **One aggregate package.** Cetus and Bluefin ship together, so the release
  gate, dependency graph, and `UpgradeCap` lifecycle are shared.
- **Vault custody.** Every migrated sale shares its own
  `blast_vault::vault::Vault<Meme, Quote>`, so unrelated fee collections never
  contend on the same Sui object. The venue position is a dynamic **object**
  field under the vault's `PositionKey<Venue>`, with no removal or transfer
  path; only code holding the venue's witness can borrow it. A venue creates a
  vault only while the vault's `VaultRegistry` admits its witness.
- **Residuals.** Whatever the pool does not take at migration enters the vault
  under the sale's terms: paid to the core `Treasury` at
  once or held for the sale's partner when the terms name Blast, or held for the
  owner otherwise. No venue stores a payout
  address, burns a nonzero residual, or sends one to `0x0`.
- **Vault-split LP fees.** The vault takes the sale's sealed terms: its
  `FeeSplit`, its partner, and Blast's share snapshotted from the product's
  LP-fee policy. A
  venue's permissionless collection hands both collected balances to
  `blast_vault::vault::split_fees`, which pays Blast's share and the address
  routes and credits the owner, auto-LP, holder-reward, and burn balances.
  Auto-LP balances wait in the vault until a live `AutoLpAdmin` keeper separately
  reinvests them through the venue's private `compound_auto_lp` entry, using inclusive
  pool-order Q64.64 sqrt-price bounds derived from a trusted off-chain quote and
  maximum slippage. Private entry restricts composition but does not isolate preceding
  completed swaps. The entry consumes and re-shares the pool, preventing its reuse by
  later commands in the same PTB. Collection needs no keeper capability; an
  add-liquidity refusal never blocks collection. The owner schedules or cancels a
  split change on the vault with an owner
  proof from the sale's product; the notice is a fixed 48 hours. Ready
  application is permissionless: the venue checks readiness, runs the same
  settlement under the old split, then applies the stored split with
  `blast_vault::vault::apply_fee_split`.
- **Creator-chosen venue tiers.** The creator passes the pool tier to the
  venue's `prepare`, which validates it against the venue and records it in
  `venue_config::VenueConfig` before the product's `new` redeems the ticket; migration
  reads it from there and never trusts a migration caller. There are no
  administrator tier pins or compiled defaults. Cetus fixes the fee rate of each
  registered tick spacing, so `cetus::prepare` takes only the tick spacing;
  Bluefin checks its bounds only when a pool is created, so `bluefin::prepare`
  applies them first. `VenueConfig` keeps only write-once venue records, under
  keys only their venue module constructs.
- **Cetus LP Burn.** Cetus migration burns the full-range position with
  `lp_burn::burn_lp_v2` (original package
  `0x12d73de9a6bc3cb658ec9dc0fe7de2662be1cea5c76c092fcc3606048cdbac27`, version 8
  at `0xc4aabc874f5060d3147d8f74c14e3a8a1f9f8d92edea138a51635395ed167cd9`, shared
  `BurnManager` `0x1d94aa32518d0cb00f9de6ed60d450c9a2090761f326752ffad06b2e9404f845`).
  Version 8 links Cetus CLMM version 15, integer_mate 7, move_stl 5, the CLMM
  vester (`0x9d2f067d…`, version 2 at `0x48dcc510…`), and the CETUS token
  (`0x06864a6f…`); `interfaces/cetus_lp_burn` declares `burn_lp_v2` and
  `collect_fee` as read from the live bytecode (no type parameters on
  `burn_lp_v2`, unlike the upstream README), and `interfaces/cetus_clmm_vester`
  and `interfaces/cetus_token` exist only so the published linkage covers LP
  Burn's dependencies. The vault keeps the `CetusLPBurnProof`; Cetus auto-LP adds
  to a second full-range position the venue opens with `pool::open_position` on
  its first add and attaches to the vault.
- **Cetus pool-creation reservation.** Any Meme holder could pre-create the
  Cetus pool for a pair and tick spacing, so `cetus::prepare` reserves creation
  before any Meme exists outside the sale's custody: it mints the Meme type's
  single `factory::PoolCreationCap` from the coin's `TreasuryCap`, which it
  borrows from the product's `blast_core::sealed_treasury_cap` seal with that
  product's admission of this venue in the sale's creation PTB, and registers
  the pair at the creator's tick spacing (Cetus admitted only 200 at 1% for
  permissioned SUI and USDC pairs on 2026-09-22). The capability is a dynamic
  object field of `VenueConfig`, so it keeps its ID; only `cetus` constructs its
  key, and nothing extracts the capability or unregisters a pair. Migration
  creates the pool with that capability at the recorded tick spacing and never
  adopts an existing pool. Cetus's pool-manager role can also create a reserved
  pair's pool without the capability. That is a trust assumption on the venue
  operator: such a pool makes the pair's migration abort, and recovering the
  sale would need a migrators upgrade.
  The seal closes the window before `prepare` (ADR 0138;
  `venue_fork::cetus_pool_cannot_be_pre_created_before_prepare`, 2026-11-05):
  Cetus `pool_creator::create_pool_v3` refuses a seed range beside the initial
  price (abort 5), so a stranger with no Meme cannot open the pool, and the
  creator holds the cap only sealed, so no Meme is minted before the product's
  `new`; Cetus keeps one pool per pair and spacing (`factory` abort 1).
- **Direct events, no wrapper.** `events.move` owns this package's raw payloads,
  typed by the pair's phantom `Meme` and `Quote` as in `blast_vault_events`, and
  is its only module that calls `sui::event::emit`; vault and fee events come
  from `blast_vault`. No envelope wraps them, so native payload filtering stays
  direct. Payloads carry no application sequence, revision, nonce, schema
  version, or action tag.

## Live ABI verifier

```bash
node scripts/check_mainnet_abi.mjs
```

Node built-ins only, no JSON-RPC. It POSTs to the official Sui mainnet GraphQL
endpoint `https://graphql.mainnet.sui.io/graphql`, and first asserts
`chainIdentifier` is the mainnet genesis checkpoint digest
`4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S` (`35834a8a`). For Bluefin Spot
and Cetus CLMM it then:

1. resolves the original package id to its current revision, because
   `package(address:)` returns the tip of a lineage;
2. re-reads the pinned revision through `package(address:, version:)` and fails
   when `packageVersionsAfter` reports any newer tip, naming that tip instead of
   silently adopting it;
3. asserts the expected current package id, version, whole-package object digest,
   and previous transaction on both the resolved tip and the pinned revision;
4. asserts every consumed struct's exact `typeOrigins` defining id — normally
   the original package id, with Cetus `PoolCreationCap` pinned to revision 8
   (`0x157468379cfe5616c063ae39a889dd184ad48350d3e08f8d9b4ade22b8e3fb61`), where
   it was introduced;
5. decodes each consumed module's on-chain bytes, checks the `0xa11ceb0b` Move
   magic, and asserts the committed SHA-256 fingerprint; and
6. asserts the normalized public ABI of every consumed Bluefin Spot and Cetus
   CLMM function and struct.

The `integer_mate` signed-integer helpers that Bluefin's full-range tick
alignment calls are outside this ABI check: that package is pinned by commit in
`Move.toml` and `Move.lock`, and its linkage entry is recorded under
[Transitive interface packages](#transitive-interface-packages).

### Response validation

The GraphQL response is untrusted input to a release gate, so every field is
validated before it is rendered. Each function and struct object must carry
exactly the requested fields; each list must be a real list; `isEntry` and
`isPhantom` must be real booleans; visibility, abilities, constraints, primitive
type names, reference kinds, and type-body shapes must each be a known value with
no duplicates. A null, absent, partial, or novel response is a failure, never a
value that normalizes into something an expectation happens to match. The live
schema omits `signature.ref` for a by-value type, so absence is the by-value
shape and any present `ref` — including an explicit null — must be `&` or
`&mut`. Type origins are built one entry at a time and reject a repeated
`module::struct` key, so a wrong defining id cannot be overwritten by a later
expected one; an exact repeat of the same defining id fails too.

The ABI comparison then uses the structured `OpenMoveTypeSignature`, not display
prose. Each entry renders reference mutability, every parameter in order,
type-parameter constraints, phantom markers, abilities, visibility, `entry`, and
the full return tuple. `@self` is the package's own original address, `@sui` and
`@std` are the framework addresses, and every other address is compared
literally, so a venue that re-points a helper type to a different package fails.
Missing or extra parameters, `&` versus `&mut`, visibility drift, ability drift,
phantom drift, and return drift each fail the run.

### Local pin validation

The same run parses `Move.toml`, the Cetus local interface manifest, and
`Move.lock` with a strict reader for exactly the record shapes those files use.
Comments are removed before any comparison, so commented-out text can never
satisfy an expectation, and a duplicate key, a duplicate table, an escape, a
nested inline table, or any unrecognized value form is itself a failure.

Each file is then bound to an exact expectation:

- every `[dependencies]` name set must match, and each record must match
  key-for-key and value-for-value — repository, subdirectory, local path,
  revision, and `override` rule included;
- every Git record in every checked manifest and in both lock environments must
  carry an immutable 40-hex `rev` and must not carry `branch` or `tag`, whatever
  the expectation says;
- `[package]` may declare only known keys, `published-at` must equal the current
  package id, package identity addresses must match their pins, and no table
  outside `package`, `dependencies`, and `addresses` may appear. Every address
  key and value is exact, so no extra named address can enter the manifest;
- `Move.lock` must declare format version 4, exactly the expected pinned nodes
  in the `mainnet` environment and no other (Blast deploys to mainnet only), each
  node's exact `source`
  record and exact resolved `deps` edges, and nothing else; every node's
  `manifest_digest` must be a string of 64 uppercase hex digits, the shape the
  Move CLI generates; and
- the local normalized interface must resolve its named `Sui` edge to a node
  whose source is `MystenLabs/sui` at
  `crates/sui-framework/packages/sui-framework` and
  `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`.

### Failure behaviour

The run fails closed. Each request has a 30-second whole-request deadline
covering both the connection and the body read; transport errors, timeouts, and
HTTP 5xx retry three times, and the body is read inside that retry boundary. A
GraphQL `errors` payload, a non-JSON body, any other non-2xx status, a missing
package, a missing module, and a missing function are immediate failures.
`--emit` prints the observed facts as a paste-ready expectation block; it never
relaxes an assertion.

### Offline self-test

```bash
node scripts/check_mainnet_abi.mjs --self-test
```

Makes no network request and mutates no file. It renders a well-formed function
and struct fixture, validates the committed manifests and lock, and then asserts
that mutated inputs are rejected — null lists, a missing or null `isEntry`,
unknown and duplicate abilities and constraints, unknown visibility, novel type
bodies and reference kinds, an explicit null `signature.ref`, extra response
fields, duplicate type origins with conflicting and with identical defining ids,
a commented-out dependency, a missing `rev`, `branch` and `tag` selectors, a
wrong-but-40-hex Sui revision, wrong repositories and subdirectories, added and
dropped `override` rules, duplicate keys and tables, extra and missing lock
nodes, rebound `deps` edges, boolean, malformed, and lowercase
`manifest_digest` values, and a struct pinned to its introducing revision
resolved against the original package. Positive fixtures pin the accepted
shapes, including a by-value parameter with `ref` absent and that revision pin.
Manifest fixtures reject an extra named address, package identity drift, and
dependency drift.
Every case that a live run cannot reach without a real venue upgrade is covered
here instead.

## Published venue packages

Re-verified on mainnet on 2026-09-02; Cetus CLMM re-pinned to revision 15 and
re-verified on 2026-09-22. All rows, Cetus LP Burn included, passed
`scripts/check_mainnet_abi.mjs` on 2026-11-04.

| Venue | Named address | Original package id | Current package id | Version | Package digest | Previous transaction |
| --- | --- | --- | --- | --- | --- | --- |
| Bluefin Spot | `bluefin_spot` | `0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267` | `0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c` | 17 | `4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut` | `CShZDVqJQrXm4SYiCgDe49kKnFzadwhFV5viqHLgRfaX` |
| Cetus CLMM | `cetus_clmm` | `0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb` | `0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084` | 15 | `9rZP5D79m4Yfq9fvtPujtpvU5rhfiYm1JS6LaxcMZVSu` | `5sSoTfTiti8kXjJhZeYuFWFcxxvjbZpFQ96rZ3dzeQbC` |
| Cetus LP Burn | `lp_burn` | `0x12d73de9a6bc3cb658ec9dc0fe7de2662be1cea5c76c092fcc3606048cdbac27` | `0xc4aabc874f5060d3147d8f74c14e3a8a1f9f8d92edea138a51635395ed167cd9` | 8 | `77pAM8TdzRbHqA4b5ccyLQHZzNNhj3k15cZMtD37qLHH` | `6m7WqScGvn4M6n5k9HE5241wGNW8izpdSCs69Smy3EKy` |

## Committed module fingerprints

SHA-256 of each module's decoded on-chain bytecode at the current revision above.
Only modules that declare a venue-consumed type or function are fingerprinted.

| Package | Module | SHA-256 of decoded on-chain bytecode |
| --- | --- | --- |
| `bluefin_spot` | `config` | `e896bcbdab23bf5c04eb38b12306f8d6ced8bb9194c789cd1f7f09c78e595cab` |
| `bluefin_spot` | `pool` | `d1436b0837eab8912797b91ed68755ad6e4228243f188a43c42ea040e844e97c` |
| `bluefin_spot` | `position` | `ea83d3b9a65c7f62579dd0a902ddad8ade46cec277e5781ab9e52783c48caaec` |
| `bluefin_spot` | `tick` | `2ac4cbe4fa1270ac16e3ffa4716fd745fef0a480dd9685947e17539b269a10f8` |
| `cetus_clmm` | `clmm_math` | `851de164740b305acc2422452e30b34fff80f366113a286719c4ee8f25d41e6f` |
| `cetus_clmm` | `config` | `d0575fcd8fa5e6d63a779a19fbc1ee276459d151d8045bc7e7a9f5f380adfad5` |
| `cetus_clmm` | `factory` | `4cd33aca821e17cccb0004e3c78ec6033b7fec0360fdf17c03393e976efa5e9b` |
| `cetus_clmm` | `pool` | `059cbeeb4502c7e54b1a9ada73709505f9572f4c80c441c1c31fbee64c32c7a1` |
| `cetus_clmm` | `pool_creator` | `23c78096ed45feda5349e098d9827f37cee0fce662544e98ea28de5f6e8c57b6` |
| `cetus_clmm` | `position` | `78f71fd13a5ab6528509d1a2ceb279e4d6616cd8e6877baf4a5ee25627789cc3` |
| `lp_burn` | `lp_burn` | `653b9673273bd5f5e237b3105959410e757abc11b08535481a40c6ae0d88930b` |

## Normalized ABI coverage

| Venue | Modules | Functions | Structs | Type origins |
| --- | --- | --- | --- | --- |
| Bluefin Spot | 4 | 15 | 5 | 5 |
| Cetus CLMM | 6 | 21 | 7 | 7 |
| Cetus LP Burn | 1 | 2 | 2 | 2 |
| **Total** | **11** | **38** | **14** | **14** |

The list contains only the Bluefin Spot, Cetus CLMM and Cetus LP Burn functions
and structs the venues actually reference; `node scripts/check_mainnet_abi.mjs`
prints these counts.

## Source pins

Every direct and overridden Git dependency in `Move.toml` is a full commit. Blast's
own packages are local path dependencies, listed in `Move.toml`.

| Manifest dependency | Kind | Pin |
| --- | --- | --- |
| `BluefinSpot` | git `fireflyprotocol/bluefin-spot-contract-interface` | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| `CetusClmm` | local `interfaces/cetus` | normalized from mainnet revision 15 |
| `Sui` (override) | git `MystenLabs/sui`, subdir `crates/sui-framework/packages/sui-framework` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| `IntegerMate` (override) | git `CetusProtocol/integer-mate` | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| `IntegerLibrary` (override) | git `fireflyprotocol/integer-library` | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |

Cetus's reviewed source manifest carries no `published-at`, so Cetus ships as a
minimal local normalized interface. It preserves the venue's original type
address and sets `published-at` to the current mainnet revision. Its bodies are
`abort 0` link stubs; they exist only to type-check and to bind the runtime
package id.

Upstream `BluefinSpot/Move.toml` itself declares mutable revisions
(`Sui = mainnet-v1.35.2`, `IntegerMate = sui-v1.1.2`, `IntegerLibrary = v1.0.1`).
The aggregate manifest overrides all three with full commits, and `Move.lock`
resolves every node — including transitive ones — to a 40-hex commit, so the
built graph contains no mutable revision.

## Resolved graph

`Move.lock` and `scripts/check_mainnet_abi.mjs` own the exact node set that
`sui move build` compiles for the `mainnet` environment.

`IntegerMate_1` is the single `09a12d9b…` integer package; Bluefin's older
`sui-v1.1.2` node is overridden away and never compiled. `MoveStdlib_2` and
`Sui_2` are the one `06734f6f…` framework pair, which the Cetus local interface
also binds in both lock environments; the lock's other framework nodes are the
upstream pins of Bluefin and its integer libraries, likewise overridden away.

Only the addresses the aggregate package's own bytecode references enter the
published linkage table:

| Address | Referenced by `blast_migrators` modules |
| --- | --- |
| `blast_admin`, `blast_core`, `blast_vault`, and `blast_migrators` | yes |
| `0x1` MoveStdlib, `0x2` Sui framework | yes |
| `bluefin_spot`, `cetus_clmm` | yes |
| `integer_mate` `0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57` | yes, Bluefin full-range tick math |
| `integer_library` `0x03637b7b60978ef4389124f7683456f0050ab015a0590d52b6e6cadb342af34a` | no, compile-only transitive |
| `move_stl` `0xbe21a06129308e0495431d12286127897aff07a8ade3970495a4404d97f9eaaa` | no, compile-only transitive |

`bluefin_spot::config::get_tick_range` returns
`0x714a63a0…::i32::I32`. Both integer-mate revisions in the graph declare that
same original address, so the overridden pin keeps one consistent `I32` type
across the Bluefin call and the venue's own tick arithmetic.

### Transitive interface packages

| Named address | Original id | Current mainnet revision | Version | Pinned `published-at` |
| --- | --- | --- | --- | --- |
| `integer_mate` | `0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57` | `0xdfaadf86be9af246900d1e3f3b996cf549e7948e662a9977bdd7646d8fa3a778` | 7 | `0xdfaadf86…` — current |
| `integer_library` | `0x03637b7b60978ef4389124f7683456f0050ab015a0590d52b6e6cadb342af34a` | `0xab5e63352d0f05881bdfa1631cc0f7fc1669175a00d608828a924df481a9e4bd` | 3 | `0xab5e6335…` — current |

Both pinned interfaces already target the current mainnet revision, so the
`integer_mate` linkage entry needs no change before publication.

## Local gate

Run from this directory:

```bash
node scripts/check_mainnet_abi.mjs --self-test
node scripts/check_mainnet_abi.mjs
sui move build
sui move lint --warnings-are-errors
sui move test --lint
sui move build -e mainnet
bash scripts/check_source_boundaries.sh
```

A local build proves type compatibility only. The interface bodies are `abort 0`
stubs, so no venue call executes in the Move tests under `tests/`; venue
behaviour is exercised by the venue fork gate below.

## Venue fork gate

`sui/launch/launchpad/ptb_tests/tests/venue_fork.rs` runs this package against the real
mainnet bytecode of Cetus CLMM, Cetus LP Burn, and Bluefin Spot, offline. It
inserts a committed snapshot, `sui/launch/launchpad/ptb_tests/fork/snapshot/`, into
Sui's in-memory simulator at the real IDs: every package those venues load
(closed over linkage and type origins) and the live shared objects and dynamic
fields their code reads, all read at one pinned checkpoint, each checked against
its on-chain object digest. It then publishes the Blast packages this one links
to, and this package against the pinned venue revisions, and drives the matrix below through public
PTBs, for Cetus with Meme as coin A (SUI Quote) and as coin B (USDC Quote, the
other Quote Cetus admits), and for Bluefin, with real swaps generating the
collected fees. The Bluefin migration with a Meme icon of about 256 KB is not in
it. It runs with the rest of the harness:

```bash
cd ../launchpad/ptb_tests && cargo test --offline
```

`fork/fetch.py` (Python standard library, read-only GraphQL) owns the pinned
checkpoint and the reason for every entry. To refresh the snapshot, run
`python3 fork/fetch.py --checkpoint latest` from `sui/launch/launchpad/ptb_tests`, set
`CHECKPOINT` in the script to the checkpoint it prints, and rerun the tests. The
fetch fails when a pinned venue lineage has a newer revision at the checkpoint,
so a venue upgrade is re-pinned here first. Refresh after any venue re-pin and
before a release.

The fork gate is the local evidence for the matrix and replaces the dev-inspect
fixtures for that purpose. It cannot see state that changes after its
checkpoint, so a mainnet dry-run of each route against live objects remains the
pre-deploy check.

## Mainnet dev-inspect matrix

The release matrix is Cetus and Bluefin. Each row below is one fixture against
the published venue packages above, in the orientation named by the route: the
venue fork gate proves it locally, and a mainnet dry-run repeats it before
deployment. No route may be skipped, and a skipped row is a release blocker, not
a documentation footnote.

Each fixture prepares its coin through the venue's `prepare` at a tier the venue
accepts, records that `VenueConfig` stores that tier, and starts the sale with
the product's `new`, which stores the venue. Each migration fixture calls the
product's `migrate` and passes the returned `Migration` to the venue's
`migrate` in the same PTB.

Each migration fixture must show:

- the balance-derived `sqrt_price_x64` matches the exact Q64.64 target for that
  orientation, with no caller-supplied price and no display-decimal scaling;
- full-range ticks come from the venue's pinned tick helpers and align inward to
  the selected tick spacing; and
- the returned position belongs to the new pool, has positive liquidity, and
  enters the vault as its one sealed dynamic object field.

Each collection fixture must show that only the vault's own position on its
own pool is collected, its liquidity is unchanged, and the collected balances
are split in full by the vault's Blast share and its current fee split. The
auto-LP share remains in vault custody.

Each separate compounding fixture must call `compound_auto_lp` and show that
liquidity grows only by the auto-LP addition, the add fixes the side the other
balance covers, and unused balances remain in the vault. A refused add must
leave previously completed collections intact.

One venue-semantics row was already **proven against published mainnet
bytecode on 2026-08-30** by disassembling the live module (fetched through the
official GraphQL endpoint, disassembled with the pinned `sui move
disassemble`); the dev-inspect fixtures re-confirm it end to end:

- **Bluefin order acceptance.** The current `bluefin_spot::pool` module
  contains no type-name comparison at all, so no canonical-order check exists
  to reject the hard-coded Meme-as-coin-A order for any Quote.

### Cetus revision-3 rows

| Route | Orientation and authority |
| --- | --- |
| `prepare` | Records the creator's tick spacing for a coin in `Quote`, reserves the pair's Cetus pool creation, and returns the ticket; the product's `new` then aborts unless its venue list admits `cetus::Venue` and the Quote |
| `migrate` | Permissionless; takes the product's `Migration` first; type arguments `<Meme, Quote, CoinA, CoinB>` with the pool's coins in Cetus order (ADR 0100); burns the position through the shared `BurnManager` |
| `collect_fees` | Permissionless; splits the collection, burns the burn part's Meme, and leaves the auto-LP share in the vault for `compound_auto_lp` |
| `compound_auto_lp` | Private entry requiring live `AutoLpAdmin` and inclusive keeper-approved sqrt-price bounds; consumes and re-shares the pool, adds waiting auto-LP balances, and retains unused balances in the vault; creates the separate auto-LP position on Cetus's first add |
| `settle_and_apply_fee_split` | Permissionless ready stored proposal; settles under the applied split, then activates the accepted split and notice |
| `buyback_and_burn` | Under the core `BuybackAdmin` role (ADR 0091); swaps the administrator's `quote_in` of the vault's burn Quote for Meme in its own pool through `flash_swap` / `swap_pay_amount` / `repay_flash_swap` at the widest sqrt-price limit, then burns the Meme if it reaches the administrator's minimum |

Each Cetus fixture must show:

- `prepare` reads the fee rate Cetus registers for the tick spacing (aborting
  when Cetus registers none), mints the Meme type's single `PoolCreationCap` from
  the coin's `TreasuryCap` and keeps it as a `VenueConfig` dynamic object
  field, registers the pair at that tick spacing (aborting when Cetus refuses
  it), and emits `CetusPoolReserved`;
- every route after `prepare` takes the pool's coins as `CoinA` and `CoinB` and
  aborts with `EWrongCoinPair` unless they are exactly the sale's Meme and
  Quote; migration first aborts with `EInvalidCoinOrder` unless Cetus's own
  `factory::is_right_order<CoinA, CoinB>` agrees with them, and creates the
  pool only with the reserved `PoolCreationCap` at the sale's tick spacing,
  never adopting one;
- liquidity is seeded with the exact handed-off balances, fixing the side with
  more atoms (Meme on a tie) unless `clmm_math::get_liquidity_by_amount` says it
  would overdraw the other balance, which nearly equal amounts can do by one
  atom; whatever the venue does not take is the sale's residual, settled by its
  terms, and supplied
  principal plus residual reconciles exactly with the hand-off;
- the position is burned with `lp_burn::burn_lp_v2`, its `CetusLPBurnProof`
  enters the vault under `PositionKey<cetus::Venue>`, the vault is shared with
  the sale's fee split, and the caller receives no object;
- the first auto-LP add opens one full-range position under
  `AutoLpPositionKey<cetus::Venue>` (`AutoLpPositionOpened`), and later adds and
  collections reuse it; and
- collection and the settled update collect only that position on its own pool
  (another pool aborts with `EPositionPoolMismatch`), leave its liquidity
  unchanged, and split through the vault, the update under the old split first;
  `compound_auto_lp` adds liquidity in a separate call.

### Bluefin revision-3 rows

| Route | Orientation and authority |
| --- | --- |
| `prepare` | Records the creator's tier for a coin in `Quote` and returns the ticket; aborts with `EInvalidTier` outside tick spacing 1–400 and fee rate 1–20,000 and with `ESymbolTooLong` above a 32-byte Meme symbol, and the product's `new` then aborts unless its venue list admits `bluefin::Venue` and the Quote |
| `migrate` | Permissionless; takes the product's `Migration` first; creates `Pool<Meme, Quote>` with Meme as coin A |
| `collect_fees` | Permissionless; splits the collection, burns the burn part's Meme, and leaves the auto-LP share in the vault for `compound_auto_lp` |
| `compound_auto_lp` | Private entry requiring live `AutoLpAdmin` and inclusive keeper-approved sqrt-price bounds; consumes and re-shares the pool, adds waiting auto-LP balances, and retains unused balances in the vault; adds to the existing migration position |
| `settle_and_apply_fee_split` | Permissionless ready stored proposal; settles under the applied split, then activates the accepted split and notice |
| `buyback_and_burn` | Under the core `BuybackAdmin` role (ADR 0091); swaps the administrator's `quote_in` of the vault's burn Quote for Meme in its own pool through `swap` at the widest sqrt-price limit, then burns the Meme if it reaches the administrator's minimum |

Each Bluefin fixture must show:

- `migrate` creates the pool at the tier `prepare` recorded and bounded exactly
  as Bluefin's pool creation does: tick spacing at most 400 (`pool` aborts 1026)
  and fee rate at most 20,000 (1027);
- the pool is created with `create_pool_and_get_object<Meme, Quote, SUI>` at the
  balance-derived `sqrt_price_x64`, full-range ticks aligned inward to the
  sale's spacing, and the caller's whole `Coin<SUI>` as the creation fee, which Bluefin
  accepts only at exactly its configured SUI amount (1038 for an unsupported fee
  coin, 1039 for any other amount); the Quote's shared `Currency` supplies coin
  B's symbol, decimals, and icon, while the Meme side passes its symbol (at most
  32 bytes, bounded by `prepare`) and an empty icon URL, so a Meme icon of
  about 256 KB still migrates;
- liquidity is seeded with the exact handed-off balances, fixing the side with
  more atoms (Meme on a tie) unless Bluefin's `pool::get_liquidity_by_amount`
  says it would overdraw the other balance, which nearly equal amounts can do by
  one atom; whatever the venue does not take is the sale's residual, settled by
  its terms, with no
  utilization bound, and supplied principal plus residual reconciles exactly
  with the hand-off;
- the position enters the vault under `PositionKey<bluefin::Venue>`, the vault and
  the pool are shared, the vault holds the sale's fee split, and the caller
  receives no object; and
- collection and the settled update collect only that position on its own pool
  (another `Pool<Meme, Quote>` aborts with `EPositionPoolMismatch`), leave its
  liquidity unchanged, and split through the vault, the update under the old
  split first; `compound_auto_lp` adds liquidity in a separate call.

## Release gate

The package stays upgradeable (ADR 0088): venues gate callers by package
version, so the venues must be able to relink after a venue upgrade, and its
`UpgradeCap` is never destroyed. Every migrators upgrade uses the compatible
policy, which no path narrows, and must bump `constants::version`:
`blast_admin::package_admin::commit_upgrade_and_advance` always advances the
stored version, so a build that keeps the old constant fails every venue
call's version check until the next upgrade, which the generic
administration can still schedule. Source omission
does not make principal custody permanent while this package or `blast_vault`
has an `UpgradeCap`: a compatible upgrade of either could add an extraction
function, since the venue's witness borrows its position from the vault. The correct
public statement is therefore that principal is held by an upgradeable package
with no exposed withdrawal path, never that it is permanently locked. Do not add
a migrator admin capability as an alternative.

A vault upgrade forces a migrators relink in the same release window: the
venues call version-gated `blast_vault` functions, so once the vault commits its
upgrade, migration and fee collection abort until the relink lands: a
compatible migrators upgrade that rebinds the vault address and bumps
`constants::version`, since every `commit_upgrade_and_advance` advances the
stored version. Schedule both together and execute them
back to back. A product upgrade forces no relink, since the venues take the
`Migration` from the PTB.

Before release, in order:

1. `node scripts/check_mainnet_abi.mjs --self-test` and
   `node scripts/check_mainnet_abi.mjs` both pass, the latter against live
   mainnet;
2. the local build, lint, test, and source-boundary gates pass;
3. every row of the Cetus and Bluefin matrix passes, including each migration,
   collection, and settled route-update route in every orientation: in the venue
   fork gate at a freshly refreshed snapshot, then as mainnet dry-runs; and
4. the deployment runbook admits exactly `cetus::Venue` and `bluefin::Venue`,
   in each product's venue list (the launchpad's `launch_config`, the presale's
   `creation_policy`) and in the vault's `VaultRegistry`
   (`blast_vault_package::schedule_witness`, then `apply_witness`), each only after
   that venue's preparation, migration routes, collection, and settled update
   are reviewed and its dev-inspect rows pass. No other venue witness exists in
   this package, and none is admitted.

After release, before a product admits a new Meme
precision, rerun the migration extremes at that precision (the smallest and
largest LP Meme and LP Quote hand-offs, in each coin order) against real venue
bytecode on each admitted venue.
