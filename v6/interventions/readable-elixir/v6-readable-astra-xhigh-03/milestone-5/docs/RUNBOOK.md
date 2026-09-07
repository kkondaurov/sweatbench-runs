# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The deposit-transfer migration adds a shared creation order to cash and credit room allocations.
It reconstructs earlier funding order using the durable operation journal, with each group's
unattributed senior funding first, without changing balances, revisions, or historical results.
Run `mix ecto.migrate` before starting the new application code. Downgrading this migration is
refused after an applied transfer because the previous release cannot follow funding across groups.
