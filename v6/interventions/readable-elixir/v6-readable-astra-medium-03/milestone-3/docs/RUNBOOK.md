# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable partner-operation records are introduced by the `CreateOperations` migration. Deployments
must run migrations before accepting traffic. Earlier reservation and credit data remain intact;
no operation records are backfilled. The gateway starts a new operation-ID namespace at this
release. Keep the `operations` table alongside domain tables in database backups: deleting its
records would remove retry protection. Its integer `id` orders first commits; retries and conflicts
do not create audit entries.
