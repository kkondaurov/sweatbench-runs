# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table through `mix ecto.migrate`.
The gateway must start its new operation-ID namespace at deployment; historical operations are not
backfilled. Keep this table with the domain tables in database backups: it holds submitted payloads,
original results, and first-commit order (the generated `id`). Removing records removes their retry
protection. No in-memory cache or restart recovery job is needed.
