# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table. Run `mix ecto.migrate` against an
existing database before serving requests with this release. No historical operation records are
backfilled; the gateway starts a new operation-identifier namespace at deployment.

Operation receipts, complete submissions, and domain records live in the same SQLite database and
survive process restarts. Include the operations table in database backups and retain its records
to preserve retry guarantees and audit history. Its generated `id` orders first commits; retries
and identifier conflicts do not change that order.
