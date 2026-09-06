# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table through an Ecto migration. Run
`mix ecto.migrate` before serving the new release. Existing groups and credit lots are preserved;
historical operations are not backfilled. The gateway must start its new operation-ID namespace
at deployment.

The `operations` table retains the complete submission, operation type (when a string), and result.
Its increasing `id` records first-commit order because insertion occurs within the same SQLite
immediate transaction as domain changes. Retries and conflicts leave that row unchanged. Preserve
this table alongside the domain tables in database backups; deleting records removes their retry
guarantee.
