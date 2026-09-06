# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable operation records are introduced by migration `20260905000002_create_operations.exs`.
Run `mix ecto.migrate` in the target environment when upgrading an existing database. The migration
preserves groups, credit lots, and allocations; it does not reconstruct pre-release operations.
The gateway must switch to its new operation-identifier namespace at deployment.

The `operations` table retains the original complete JSON submission, its type (when a string),
and the JSON result for every identified applied or rejected operation. Its increasing `id`
records first commit order under SQLite's serialized writer transactions. Retries and conflicts
create no additional record. Preserve this table alongside the accounting tables in backups;
deleting its records would remove the corresponding retry guarantees.
