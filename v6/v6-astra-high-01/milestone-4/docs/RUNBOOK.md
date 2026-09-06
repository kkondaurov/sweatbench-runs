# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills funding provenance before serving the new API. It preserves
cash, applied credit, credit-lot balances, group revisions, and durable operation results. Legacy
funding becomes an unattributed senior block; durable funding follows retained operation types and
commit order. Existing cancelled groups receive historical payment dispositions and credit
entitlements where durable payments exist. Run `mix ecto.migrate` with the service stopped before
starting the new version. Do not run the previous service version against the upgraded database:
it does not maintain room allocations or payment dispositions.
