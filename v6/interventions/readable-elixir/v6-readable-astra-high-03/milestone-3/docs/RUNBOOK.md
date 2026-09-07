# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` audit table. Run `mix ecto.migrate` against
the existing database before serving this release. The gateway must start its new operation-ID
namespace at deployment: operations from earlier releases have no reconstructed idempotency records.

Audit records retain the full submitted JSON, operation type (when a string), and original result.
Order records by their generated `id` to inspect first-commit order; SQLite serializes these writes.
Retries and identifier conflicts do not change this order. Keep this table with reservation and
credit data in backups and restores. Deleting audit records would remove the corresponding retry
guarantee. The service keeps no process-local retry cache, so restarting the application or database
connections preserves the guarantee.
