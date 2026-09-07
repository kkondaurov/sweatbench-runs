# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration imports preexisting funding without replaying operations. For active
groups, unattributed cash and then legacy credit consumption form a senior block; applied durable
funding follows in audit commit order. It also attributes settled cash and converted-credit
entitlements for previously cancelled groups. Existing results, revisions, cash entries, and credit
balances are preserved. Cancelled groups' lodging totals become zero to follow the active-room
totals contract.

Downgrading this migration is supported only before any room cancellation or payment correction
has been applied, because the previous schema cannot represent those accounting facts.

Cash allocations store current dispositions; immutable cash entries and operation records retain
historical facts. Payment statements and the ledger read the same allocations. Credit entitlements
are fixed at issuance, while a lot's unrecovered clawback tracks restoration absorption. Perform
accounting changes through partner operations so these records and group totals commit together.
