# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills each existing group's policy from its original
`booked_on` and rate plan, and copies its current paid deposit into its cash balance. Run
`mix ecto.migrate` before serving requests with this release. Credit lots and their active deposit
allocations are persisted in SQLite and survive restarts; no expiry worker is required. Dated
credit and ledger reads evaluate expiry without changing stored balances.
