# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds `partner_operations` without rebuilding existing reservation
or credit data. Deploy it with a new gateway operation-identifier namespace; operations submitted
under earlier releases have no reconstructed results. Apply `mix ecto.migrate` (or
`MIX_ENV=test mix ecto.migrate` for a test database) before starting the upgraded service.

The SQLite database contains both domain state and the operation audit. Back up and restore them
together using a consistent SQLite backup. Retain the audit records to preserve the retry guarantee
across restarts. `partner_operations.id` gives the order of first commits; retries and conflicts do
not add records or change that order. The `payload` contains the complete submitted JSON, including
invalid or missing types; `type` separately records its submitted string value when present.

After a `500` or lost response, retry the original batch unchanged. Earlier committed operations
will replay their results. Use a fresh operation identifier when correcting a handled rejection.
