# 0095: Partner codes in one immutable package

- Status: proposed
- Date: 2026-09-26
- Amended by: [0097](0097-one-singleton-acl-with-typed-roles.md): the partner
  administrator is the `blast_partners::PartnerAdmin` role in the singleton Blast
  ACL; the package no longer creates its own `BLAST_PARTNERS` domain
- Amended by: [0098](0098-launch-creation-fee-and-partners.md): on the launchpad
  a partner is set once per launch at creation, and is paid its share of the
  creation fee and of Blast's trade fees when Blast claims them; `buy` and `sell`
  gain no partner variants
- Amended by: [0106](0106-presale-partners.md): a presale may name one partner at
  creation, which earns its share of Blast's raise share once the sale migrates
- Amended 2026-11-03 (with [0134](0134-delayed-administration-pause-and-table-acl.md)): share
  and cap changes move from the util `Timelocked` to keyed `blast_admin::delayed::Delayed`
  values with a fixed seven-day notice, explicit permissionless application and PartnerAdmin
  cancellation; payouts read the applied share without a Clock; `blast_partners` no longer
  depends on the timelock

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui (the pinned framework) |
| `util@63b6cf8` | `63b6cf86c0e1a74f699610fe182b1de8d8789a14` | [preserved utility source](https://github.com/interest-protocol/blast-v2-contracts/tree/63b6cf86c0e1a74f699610fe182b1de8d8789a14) |
| `deepbook@a60c1ee` | `a60c1eeeec65a61ebc8c76e58492f5dee0674840` | MystenLabs/deepbookv3 |
| `dhedge@f09febf` | `f09febf528895fdd5b69f68b0dd3a9bb7d9ecc0c` | dhedge/V2-Public |
| `dydx@127ef76` | `127ef76506ccca909d937920980c1ae2d9b736a5` | dydxprotocol/v4-chain |

## Context

Integrators that build on Blast (wallets, trading frontends, bots, aggregators)
asked for partner codes. On 2026-09-26 the owner set the model: a partner earns
a percentage of the fee Blast charges on every trade that names it, sent straight
to the partner's address; Blast's administrator sets each partner's share from 0
to 80%; the partner sets its recipient with a `PartnerCap`; a partner that wants
an extra fee adds it in its own transaction. The same model serves Boosts now and
the launchpad later. The owner then asked for:

- a forced timelock on Blast's powers over partners: every change to a share or
  a cap takes effect seven days later, and nobody can shorten that; a new deal's
  share applies from registration (owner, 2026-09-26);
- that timelock as its own immutable package in the public util contracts, for
  anyone to reuse;
- one cap per company across several deals, each with its own share (for
  example 50% on Boosts and 8% on another product);
- an event for every payment a partner receives;
- plain `mint` and `redeem` left exactly as they were, with separate entry points
  for trades that name a partner, so the many users without one pay for nothing
  extra.

Two program families exist elsewhere. In one, the integrator adds its own fee on
top (Hyperliquid builder codes; dYdX builder codes capped at 1%,
`dydx@127ef76:protocol/x/clob/types/message_place_order.go:28`). In the other,
the protocol pays a partner part of the fee it already charges (dYdX order
routers up to 80% of the protocol fee,
`dydx@127ef76:protocol/x/revshare/keeper/msg_set_order_router_rev_share.go:16`;
dHEDGE referrers paid "from manager's portion only, DAO share is never
affected", `dhedge@f09febf:contracts/utils/PoolLogicLib.sol:163`). The add-on
family exists there because orders are executed after the user signs, so consent
has to travel inside the protocol. On Sui the user signs the whole transaction,
and a frontend adds its own fee with one coin split that no contract cap could
stop. Only the carve-out needs the contracts.

Failures on record: Aftermath perpetuals lost about 1.14M USDC on 2026-04-29 to
an integrator fee that went negative; DeepBook spot lets a referrer raise its
rate after users bind to it; Level Finance lost about $1.1M to referral tiers
lifted with flash-loaned volume; partner programs that write a shared partner
object on every trade serialize that partner's flow. The launchpad's earlier
referral proposal (ADR 0009) rejected per-trade
payouts because the referrer was any address the caller passed; a code Blast
issues answers that.

## Decision

**Delayed terms (amended 2026-11-03).** A partner's share and managing cap are
`blast_admin::delayed::Delayed<ShareKey, u64>` and `Delayed<CapKey, ID>` values,
created with the partner's UID, so every lifecycle event the primitive emits is
keyed and owned by that partner. Both start applied at registration with the
fixed `PARTNER_CHANGE_DELAY_MS` (seven days) notice. PartnerAdmin proposes a value
with `schedule_value`; a different proposal replaces a pending one and restarts the
full notice, and proposing the applied or the pending value aborts. Anyone may
apply a ready proposal, so a partner can apply a raise itself; PartnerAdmin may
cancel a proposal even after readiness. The module never calls the primitive's
notice-changing functions, and a boundary gate rejects them, so the notice stays
seven days. Payments and recipient checks read applied values without a Clock.
This replaces the util `blast_fun_timelock`, whose lazily switching values made a
change take effect without a transaction; the primitive makes every change an
explicit, replayable transaction and aligns partners with ADR 0134. The timelock
stays in the repository as a published immutable package that no Blast package
depends on.

**The partner package.** `blast_partners` is a leaf package that depends only on
`blast_admin`. Boosts and the launchpad are independently
deployed peers, and the Boosts core is immutable, so no existing package can hold
a type both read. It is published and made immutable in one transaction
(`sui/launch/partners/scripts/publish_immutable.sh`): the delay is only as credible as
the packages that enforce it. It has its own `blast_admin` domain,
`BLAST_PARTNERS`, with one role, the partner administrator. One role covers
registering, scheduling shares and moving partners between caps: a registration
pays only on flow that names the new deal, share changes and cap moves wait the
delay, and the root can revoke the role at once, so splitting them per action
(ADR 0094) would protect nothing more.

**Partners and caps.** A `Partner` is one deal: a shared object with a
`recipient`, a `share_bps` of Blast's fee (at most 8,000, delayed) and the ID
of the cap that manages it (delayed). A `PartnerCap` is a company's authority
over the recipients of every partner bound to it; one cap can manage any number
of partners, each with its own share and recipient. `new_cap` mints a cap that
controls nothing until Blast registers a partner under it, so anyone may mint one.

- `register(cap_id, recipient, share)` shares a partner managed by that cap,
  with its share in force at once.
- `schedule_share` proposes a share; anyone calls `apply_share` after seven days.
- `schedule_cap` proposes another cap, to replace a lost or stolen cap; anyone
  calls `apply_cap` after seven days. Until then the current cap keeps working.
- `cancel_share` and `cancel_cap` (PartnerAdmin) discard a proposal, even a
  ready one.
- `set_recipient`, called with the partner's live cap, changes the recipient at
  once.
- `destroy_cap` destroys a cap, live or not.

**Payment.** `pay(partner, fee, ctx)` takes a product's own fee on one trade,
sends the partner `floor(fee × share / 10_000)` as a `Coin<T>` with
`transfer::public_transfer`, leaves the rest in `fee`, and returns the amount.
Each positive payment creates one owned coin at the partner's recipient address;
zero payments create no coin, keeping payouts visible to tools that scan owned coins.
The transaction context is used to create the coin. Every positive payment emits
`PartnerPaid<T> { partner_id, amount }`; a zero share sends and emits nothing. Anyone calling `pay` pays the partner from their own balance, so
the event always records money the partner really received. `PartnerUpdated
{ partner_id, recipient }` is emitted at registration and on every recipient
change; the share and cap lifecycle is `blast_admin::delayed`'s `DelayedCreated`,
`DelayedScheduled`, `DelayedCancelled` and `DelayedApplied`, keyed by `ShareKey`
or `CapKey` with the partner as `parent`.

The deployed partner package is immutable. This payout change requires a fresh
partner publication and relinking its consumer packages; the existing mainnet
package keeps its original payout behavior.

**Boosts.** `operations::mint` and `operations::redeem` are unchanged.
`mint_with_partner` and `redeem_with_partner` take `&Partner` after the
`Protocol`, run the plain operation, and then pay the partner out of the admin fee
it just retained: the increase in Blast's admin cash across the operation is
exactly that fee. The reserve fee, the shares minted and the redemption net are
the plain operation's. `PartnerFeePaid<Product> { vault_id, partner_id,
admin_fee, partner_fee }` records the payment against the vault, also when the
partner is paid nothing, so the flow stays attributed. It carries no admin-cash
total: it follows the operation's `Minted` or `Redeemed` in the same transaction,
and Blast's admin cash is that event's `admin_cash_after` minus `partner_fee`. The adapter
keeps partner delivery in the shared partner package, and only `operations` calls
`pay` (source gate).

**Each product accepts its own partners** (owner, 2026-09-26). A deal is priced
for one product, so a product pays only the partners it accepts: otherwise a 50%
Boosts deal could be named on the launchpad. Boosts keeps the list on its
`Protocol`, one dynamic field per partner under `PartnerKey(ID)`, whose value is
the time the partner stops being accepted (`u64::MAX` until removed). The
`Protocol` layout does not change, and partner trades take no new object: they
already read `&Protocol`. The Boosts risk administrator, who already sets each
vault's admin share and withdraws its admin cash, calls `operations::add_partner`
and `operations::remove_partner`. Adding is instant and cancels a pending removal.
Removing takes effect `blast_partners::delay_ms()` later, and the partner stays
accepted and paid until then; the owner ruled no instant removal is needed, since
a bad cap redirects only that partner's payouts. `mint_with_partner` and
`redeem_with_partner` abort with `EPartnerNotAccepted` before any venue work for
a partner Boosts does not accept. `PartnerAdded` and `PartnerRemoved { partner_id,
accepted_until_ms }` record every change.

**The launchpad, later.** `buy` and `sell` gain partner variants that pay from
Blast's protocol portion of the trade fee in both assets, for partners the
launchpad accepts; the creator's share and the sell burn are untouched. The
opening round's permissionless settlement pays no partner.

**Tiers** are set off chain from the Blast fee kept on each partner's attributed
flow. No on-chain volume counter exists.

## Alternatives considered

**An on-chain add-on fee, Hyperliquid style.** Rejected: the user signs the whole
transaction, a contract cap cannot bound a frontend's own coin split, and the
code path is where Aftermath lost funds. Partners add their fee in their own
transaction; Blast takes no cut of it.

**Every mint and redeem naming a partner, with a zero-share house partner for
direct flow.** Rejected by the owner: most flow has no partner, and it would pay
for an extra shared input and the settlement step on every trade. It also needed
a house object at launch.

**Cashback set by the partner.** Dropped by the owner; a partner rebates its
users itself.

**One cap per partner.** A company with several deals would juggle several caps;
one cap per company with a timelocked cap ID per partner keeps each deal's share
separate.

**An owner address instead of a cap.** Both are equally exposed to a stolen key;
the cap lets the partner move custody without Blast, and the timelocked cap ID
lets Blast replace a lost one.

**Keeping the util timelock (superseded 2026-11-03).** Its lazy reads needed no
apply transaction, but a change took effect with no event at that moment, and the
partner package diverged from every other delayed Blast setting.

**The partner type inside the Boosts adapter or core.** The launchpad could not
use it without depending on a peer product, and the core is immutable.

**Upgradeable packages.** An upgrade could shorten the delay. Changing the ABI
means publishing new packages and registering partners again.

**The partner recording its product.** A product type set at registration and
checked by `pay` needs no list, but gives products no control of their own, writes
product type names into an immutable package, and is set by the same partner
administrator. A per-vault list has the wrong grain: deals are per product.

**Accrual with claims, binding codes to a gas sponsor.** Each adds state or a call
without a property the push payment or a public code does not already give;
binding would also shut out wallet partners, the largest builders on Hyperliquid.
An apply step and a cancel function, rejected originally, are accepted by the
2026-11-03 amendment: permissionless application needs no keeper, since the
partner itself can apply a raise.

## Consequences

- Blast cannot stop a stolen cap in under seven days: the thief's recipient
  changes are instant and `schedule_cap` waits. Exposure is each bound partner's
  share of Blast's fee for seven days; integrators can stop naming the partner
  meanwhile. Partners should hold their cap in a multisig.
- A new partner earns from registration, on each product that accepts it. A
  rogue partner administrator's new deal pays nothing until a product's risk
  administrator accepts it, so both domains must agree before a deal pays.
- The delay protects partners from targeted cuts only: Blast still sets each
  vault's admin share at once, and partners earn nothing while it is zero, its
  value at activation.
- A recipient the collateral's deny list blocks is expected to make partner
  trades abort, since Sui checks deny lists for coin transfers; the
  release rehearsal confirms it. The partner fixes it instantly with its cap, or
  integrators call the plain entry points.
- Codes are public: anyone can name any partner a product accepts. The partner earns on that flow;
  Blast bounds its exposure per partner with the share and prices tiers on
  retained fee, which free-riding lowers. Self-referral never pays: every trade
  still pays the reserve fee and at least a fifth of Blast's fee, plus venue
  costs.
- The adapter ABI gains the two partner entry points, `add_partner`,
  `remove_partner` and three events; `mint`, `redeem`, `Minted` and `Redeemed`
  are unchanged. The SDK, the indexer reducers and the release PTB builder add
  them, and the SDK reads a partner's `PartnerKey` field to fall back to the
  plain entry points once a removal takes effect.
- The adapter changes ship in a fresh publish of the Boosts adapter (owner,
  2026-09-27), not an upgrade of the live alpha adapter, so it keeps compiling
  generation 1, the generation its own initialization shares.
- The new adapter links `blast_partners` by its published address, so
  `blast_partners` is published, and its `Published.toml` committed, before
  the adapter's mainnet build.
- The partner administrator sets each deal's terms in its own domain; the Boosts
  risk administrator decides which deals Boosts accepts.
- The Boosts removal notice is as strong as the adapter's governed upgrades, not
  immutable like the share and cap delays: the adapter is upgradeable.
- Removed partners stay as inert dynamic fields under `Protocol`; only the risk
  administrator adds them, and nothing iterates them.
- `blast_partners` depends only on immutable `blast_admin`; its own module fixes the
  notice. Payout APIs across products take no Clock for the partner share.
- A ready proposal does not change payouts until someone applies it, so a cut
  Blast proposes keeps paying the old share until applied; anyone can apply it.

## Verification

- `blast_admin::delayed` tests: notice boundaries, replacement, cancellation,
  application and overflow.
- Partner tests: every guard with exact aborts and guard precedence; the delay
  pinned at seven days; a registered share and cap in force at once with their
  `DelayedCreated` events; a proposed share and a moved cap at their boundaries and
  only after explicit, permissionless application; cancellation after readiness;
  a replacement restarting the notice; the recipient changing at once; one cap managing
  two partners with different shares; a cap anyone mints controls nothing; a
  partner whose cap is destroyed still paid and moved to a new cap; `pay`
  against a rounded-down reference sweep, at the largest fee, and its
  `PartnerPaid` event, which a zero payment does not emit.
- Accepted partners: added at once and a removal at its boundary; a pending
  removal cancelled; a removed partner added again; refusals for adding twice,
  removing twice, and removing an unknown or removed partner; the version guard,
  the risk role and the list's own refusals, in that order, for both calls; the
  events.
- Adapter tests: a partner is paid only out of the admin fee its operation
  retained, derived from the admin cash before it, leaving earlier admin cash,
  the reserve and the supply alone; the 80% maximum leaves Blast a fifth; a ready
  but unapplied share pays nothing but is still attributed, and an applied one
  pays in full; `PartnerFeePaid` and
  `PartnerPaid` agree; the event reducer replays `PartnerFeePaid` after `Minted`
  and `Redeemed` and matches the vault's admin cash.
- Gates: `scripts/check_admin_delay.py` (fixed notice, no notice-changing call,
  Clock-free payment), `sui/launch/partners/scripts/verify.sh`, the adapter's
  `verify.sh local` and boundary gate, the composition tests, the style check.
- Still to run before release: a live rehearsal of a partnered mint and redeem
  that verifies the recipient's transferred coins,
  and a deny-listed recipient, is a release gate that has not been run. The
  partner entry points cannot run locally against the Aftermath stubs, so the
  rehearsal also covers `mint_with_partner` and `redeem_with_partner` end to end,
  including a partner Boosts does not accept aborting before any venue effect.
