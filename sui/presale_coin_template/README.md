# Presale coin template

This compiler-input package creates one sale token when it is published: the
coin a Blast presale sells. Like the
[launch ticket template](../launch_ticket_template/README.md), the SDK does not
compile this source per coin. It patches the compiled module's constants and
renames its `presale_coin` module and `PRESALE_COIN` one-time witness after the
coin, so the coin type is `<package>::<module>::<WITNESS>` and the Coin Registry
proves it is unique.

The package exposes no public functions. Its initializer passes the witness and
the reviewed constants to `blast_presale::sale_token::new`, which creates the
currency and returns its registry initializer beside the `TreasuryCap` sealed
under the presale (`blast_core::sealed_treasury_cap`). The initializer transfers
the sealed cap to the publisher, who can never mint through the seal, and
delivers or deletes the `MetadataCap` as the constants say:

| Constant | Meaning |
| --- | --- |
| `SYMBOL`, `NAME`, `DESCRIPTION`, `ICON_URL` | coin metadata; the symbol must be ASCII printable |
| `DECIMALS` | decimal places |
| `METADATA_MUTABLE` | `true`: the `MetadataCap` goes to `METADATA_CAP_RECIPIENT`; `false`: it is deleted and the metadata is frozen |
| `METADATA_CAP_RECIPIENT` | receives the `MetadataCap` when the metadata is mutable; unused otherwise |

The native `Currency` is delivered to the Coin Registry address; anyone may
complete its registration with `coin_registry::finalize_registration` in a
later transaction. The publisher keeps the `UpgradeCap`. The publisher starts
the sale by passing the sealed cap to an admitted venue's `prepare` and then to
`blast_presale::blast_presale::new`, the only call that opens the seal.

The design is recorded in
[ADR 0138](../../docs/decisions/0138-sealed-treasury-caps-and-venue-admissions.md).
`scripts/check_source_boundaries.sh` keeps the template to its initializer and
its replacement slots. This package's source, manifest, and lockfile own the
implementation and dependency facts.
