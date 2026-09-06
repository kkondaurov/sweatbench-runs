# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table through `mix ecto.migrate` (use the
deployment's environment and database configuration). Existing groups, credit lots, and allocations
are preserved. The gateway must start a new operation-identifier namespace at this deployment;
records are not reconstructed for operations submitted to earlier releases.

The operations table is both the retry store and the audit trail. It retains the complete JSON
payload, operation type (when supplied as a string), and original JSON result. Its increasing `id`
orders first commits, including rejections; retries and conflicts do not add records. Preserve this
table with the domain tables in database backups and restores, and do not prune it independently:
removing records removes their at-most-once guarantee. Application or connection-pool restarts do
not require rebuilding any in-memory retry state.
