# Presale test Quote faucet

This package supplies a worthless Quote coin, `test_sui::TEST_SUI`, and its
permissionless faucet. Use it only with disposable test balances.

Create each sale token by publishing the [presale coin template](../../templates/presale_coin_template/README.md).
Its initializer calls `blast_presale::sale_token::new` with the coin's one-time
witness, so the TreasuryCap is sealed under the presale from birth. Finalize the
currency's registry registration, obtain the product's venue admission, prepare
the venue with the sealed cap, then pass that cap to the presale constructor.

A runtime-created raw TreasuryCap cannot become a presale sale token: the
publisher already had mint authority before any seal. The old `sale_tokens`
constructors have been removed rather than adding a way around that custody
rule. The template's Move tests and `presale_venue_fork` exercise the supported
currency publication and sale-creation flow.
