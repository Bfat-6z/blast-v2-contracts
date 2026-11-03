# Blast vesting

This independent, framework-only package provides fully funded,
fixed-beneficiary linear and bounded-checkpoint schedules. Claims are
permissionless and cannot redirect payouts; cancellable schedules return only
unvested value to their fixed refund recipient.

The design is recorded in
[ADR 0052](../../docs/decisions/0052-stepped-linear-vesting.md) and
[ADR 0055](../../docs/decisions/0055-global-vesting-package-and-checkpoints.md);
[`vesting.json`](../../docs/vectors/vesting.json) fixes the chain-neutral
arithmetic boundaries. Use `scripts/check_coverage.sh` for the package coverage
gate. Source and tests own the current API, errors, events, and schedule
behavior.

Events carry no sender field; indexers read the sender from the transaction
and join later events to `VestingCreated` by `vesting_id`.

A coin whose issuer keeps a deny list can stall a schedule. While the
beneficiary is denied, claims fail, and so does cancellation whenever vested
value is owed. While the refund recipient is denied, cancellation fails until
nothing is left to refund.

## Mainnet

Published at
`0x85fdb7e3d28162b99e0df758069a3d23cff874c400b2160fc0d4618aefd3ec5c` and made
immutable after the mainnet gate: irrevocable and cancellable schedules with
the full 256-checkpoint vector were created, decoded, claimed at their first,
middle, and final checkpoints, canceled, and closed.
[`3wvDSfNADFGP9SvxWPuiBGvdYMvzf7BabUBpGWKD1FWu`](https://suiscan.xyz/mainnet/tx/3wvDSfNADFGP9SvxWPuiBGvdYMvzf7BabUBpGWKD1FWu)
then consumed the package `UpgradeCap` with `0x2::package::make_immutable`.
The [deployment record](../../deployments/sui/mainnet/2026-09-24-otc-and-vesting.json)
holds every digest, gas cost, object size, and reconciliation.
