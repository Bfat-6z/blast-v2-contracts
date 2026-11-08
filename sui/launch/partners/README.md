# Blast partners

`blast_partners` holds Blast's partner codes, shared by every Blast product. A
company holds one `PartnerCap` for all its deals; each deal is a `Partner` with
its own share of Blast's fee and its own recipient. A product pays a partner its
share of the fee Blast charges on a trade by calling `pay`, which emits
`PartnerPaid`; the product records the trade in its own event.

The initial share and managing cap apply immediately at registration. Later
changes Blast makes to a partner (its share and which cap manages it) are
proposals held in `blast_admin::delayed` values with a fixed seven-day notice;
anyone may apply one once ready, and Blast's partner administrator may cancel it.
The module never changes the notice. The shared UpgradeCap manager holds its
compatible cap with a fixed 48-hour wait per request. Its intended
immutability is deferred. See the [deployment record](../../../deployments/README.md). Payments read the
applied share and need no Clock. The cap holder's recipient changes apply at
once.

Read [ADR 0095](../../../docs/decisions/0095-partner-codes.md) and the
[guide](../../../docs/partner-codes.md) before changing this package.
`scripts/verify.sh` runs the package gate.
