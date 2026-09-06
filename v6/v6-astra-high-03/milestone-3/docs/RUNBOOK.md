# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table. Run `mix ecto.migrate` before serving
traffic with the new release and coordinate the gateway's new operation-identifier namespace.
Earlier submissions are not backfilled; idempotency begins with submissions received by this release.

The table retains the complete submitted JSON (including the type) in `submission`, the original
JSON response in `result`, and a unique `operation_id`. Its generated `id` orders first commits:
SQLite serializes writers, and the audit row commits with the domain changes. Retries and conflicts
do not update that row or its order. Preserve this table alongside reservation and credit data in
database backups; deleting records would remove their retry protection.
