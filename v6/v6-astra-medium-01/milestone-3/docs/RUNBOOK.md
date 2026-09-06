# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable operation records are introduced by migration `20260905000002_create_operations`.
Run `mix ecto.migrate` in the deployment environment before serving the new release. Earlier
reservation and credit data remain intact; no prior operation records are reconstructed. Coordinate
the gateway's new operation-identifier namespace at deployment.

The `operations` table retains each usable identifier's first submission and result, including
rejections. Its increasing `id` records first commit order, because inserts share the SQLite write
transaction with domain changes. `type` holds the submitted string type (or null for a malformed or
missing type); `submission` retains the complete JSON object in every case. Preserve this table
alongside reservation and credit tables in database backups and restores. Removing its records
removes the associated retry guarantee and audit history.

SQLite serializes writers. If contention exceeds its lock timeout, the request can return `500`;
the gateway should retry the batch with the original identifiers and payloads. An operation whose
transaction never began has no durable record, while earlier committed results replay normally.
