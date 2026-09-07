# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills existing accounts inside the migration transaction.
It allocates unattributed cash and credit before journaled funding, using durable commit order
rather than operation dates. It preserves cash and credit balances and original journal results.
Run migrations before serving requests with the new release. The backfill uses SQL and its own
historical data transformation so future runtime schema changes do not alter the upgrade.
