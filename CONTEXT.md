# Domain language

- **Launcher:** the account that creates a coin. Launching does not grant creator authority.
- **Creator recipient:** the account or wallet designated to claim a coin's creator authority. It may differ from the launcher.
- **Blast account:** an application identity to which one or more external login methods may be securely linked.
- **Claimant:** the wallet receiving creator authority after proving it is the designated creator recipient.
- **Origin:** the source object associated with fees, vault terms, or an owner proof. It identifies provenance, not the beneficiary or entitlement.
- **Parent object:** the object that contains a setting, partner list, or fee ledger. Use `parent` for containment; reserve `owner` for entitlement or ownership authority.
- **Owner authority:** the product's recognized right to claim the owner's share or change owner-controlled settings. It is distinct from an origin and from the parent object that stores a value.
