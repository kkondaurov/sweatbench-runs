# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills allocations atomically. It uses aggregate funding minus
applied journaled funding to identify the unattributed senior block, then processes retained
funding types in journal commit order. Operation dates do not control allocation order. Existing
credit allocations supply original lot-consumption order. Existing cancelled payments are also
backfilled for reconciliation and chargebacks; original journal submissions and results stay intact.

Cash allocations are the source of truth for current cash dispositions. The old group settlement
columns remain as migration-era snapshots and are no longer used for finance reads. Credit
entitlements retain each payment's rounded share of each issued lot; credit allocations remain
fungible and do not attribute spending to individual cash payments.
