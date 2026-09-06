# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable operation records begin with the durable-operations release; migrations do not reconstruct
records for older submissions. The gateway must start its new operation-ID namespace at deployment.
The `operations` table retains the full submission, type, and original result; its increasing `id`
records first-commit order. Retain these records with the domain database when backing up or
restoring the service so retry guarantees remain intact.
