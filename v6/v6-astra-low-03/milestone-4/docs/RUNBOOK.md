# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills active room allocations before new operations are accepted.
It puts unattributed legacy cash and credit ahead of funding in durable-record commit order, without
changing funding or credit balances. It also reconstructs dispositions for durable payments on
previously cancelled groups. Run `mix ecto.migrate` against the selected database before starting the
new release; no operation-history reset or manual balance adjustment is needed.
