# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable partner operations are stored in `operation_records` alongside the reservation tables.
Run `mix ecto.migrate` before serving traffic for this release. The gateway must start its new
operation-identifier namespace at deployment; migrations do not reconstruct records for earlier
submissions.

These records are an append-only audit, not an expiring response cache. Retain them with the domain
database in backups and restores. Each row retains the operation type (when supplied as a string),
complete submitted JSON, and original result. Ascending `id` gives first-commit order because all
first submissions acquire SQLite's immediate write lock before inserting. Retries and conflicts
neither append records nor change that order.
