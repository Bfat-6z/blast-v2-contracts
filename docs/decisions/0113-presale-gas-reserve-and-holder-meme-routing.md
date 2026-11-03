# 0113: Presale gas reserve and holder Meme routing

- Status: accepted
- Date: 2026-10-10
- Amends: [0099](0099-standalone-overflow-presale.md)

## Decision

One canonical `holder_rewards::Round` holds holder assets separately from an
optional bounded Quote gas reserve. `publish_round` atomically funds both from
the vault, stores the governed fee-policy destination, and advances its number
and holding end. The administrator explicitly supplies the reserve amount for
each round. Zero disables reimbursement and stores no pending reserve; a
positive amount enables it. There is no deployment-wide default.

Publication binds the administrator's expected treasury address in the signed
transaction and requires it to equal the governed destination at execution,
before funding. A treasury change after planning or signing aborts the stale
publication. It never rewrites the frozen round's recipient commitment. This
binding also applies when reimbursement is disabled.

RewardsAdmin settles an enabled reserve exactly once: reimburse a chosen amount
no larger than reserve, then return the entire remainder. The contract bounds
custody; trusted off-chain evidence determines eligible actual gas cost.
Permissionless close returns unclaimed holder assets and any unsettled reserve,
including after authority loss. Passing a deadline alone returns nothing.
Holder claims never consume gas custody. Merkle domains and proof semantics
remain unchanged. A round with reimbursement disabled can devote its entire
holder Quote budget to holder leaves.

Fee collection preserves protocol, partner and creator splits and rounding.
Only the holder Meme remainder is paid to the current governed fee-policy
destination; holder Quote accrues. `FeesCollected` records allocations and
`HolderMemePaid` records the exact payment and remaining unallocated Meme.
Reducers consume both in native event order. No caller supplies a recipient.

## Publication boundary

The user explicitly chose republication without backwards compatibility.
The canonical Round layout, publication/claim/settlement/close APIs and events
are updated together with SDK and backend consumers. There is no duplicate
reserve round, compatibility wrapper or legacy unallocated-Meme reconciliation.
The old dependency-only deployment cannot activate these source changes.
A fresh lineage must grant its own ACL roles and verify its governed policy
and deployment bindings before financial execution. This decision authorizes
source implementation and rehearsal; it does not authorize live publication
or financial transactions.

## Alternatives

A treasury reward leaf cannot return unused actual-cost reserve. Caller-selected
recipients create an extra authority seam. Requiring reimbursement on every
round prevents Blast from covering gas. All are rejected.

## Evidence

The approved shared-ingestion/outbox financial decisions own the economics.
The user's 2026-10-10 clarifications remove compatibility requirements and make
gas reimbursement an explicit per-round administrator choice. Local Move, SDK
and indexed tests verify source semantics; they are not live publication proof.

## Bonding-curve holder rewards, 2 November 2026

The same optional reserve and recovery lifecycle now applies to migrators'
`blast_holder_rewards::Round`. Its canonical reimbursement treasury is the
migrators-owned `LpFeePolicy.protocol_destination()` at publication. The signed
expected destination must match even for zero reserve, and later policy changes
cannot rewrite a round's frozen treasury. Holder Meme routing is unchanged:
bonding-curve Meme rewards remain holder funds, rather than adopting presale's
Meme-to-treasury collection rule.

Bonding rounds now take a future claim deadline. Claims stop exactly at it;
permissionless close at or after it returns unclaimed holder assets and any
unsettled reserve to the exact funding vault, without rewinding checkpoint or
round history. Settlement remains possible until close, including after the
deadline. Current-generation guards protect every transition. Same-PTB failures
must roll back reserve extraction, treasury payment, restored vault funds and
events together.

This changes the greenfield Round layout, public publication and claim APIs,
and event ABI together. Consumers must supply the LP policy, expected treasury,
reserve, deadline and clock; handle gas settlement and close; and decode the
extended publication plus settlement/recovery events. No compatibility wrapper,
existing-object migration or live deployment is included.
