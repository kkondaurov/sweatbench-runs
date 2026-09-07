# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The deposit-transfer migration adds a persistent transfer marker to cash payments and records
settled cash by payment and group. It backfills earlier settlements against each payment's original
group without changing balances, revisions, or durable results. Run `mix ecto.migrate` before
starting the new application version. The room-funding allocation order remains intact across the
upgrade, so transfers and provider corrections continue from existing funding.
