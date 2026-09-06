# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations migration adds the `operations` audit table. Run `mix ecto.migrate` against
the deployment database before serving the new release. The gateway must start its new operation-ID
namespace at this rollout; submissions from older releases are not reconstructed.

The audit table retains each complete submitted payload, its original result, and its type (when
the submitted type is a string; malformed type values remain in the payload). Order by `id` to
inspect first-commit order. Retries and conflicts do not append or replace records. Preserve this
table alongside reservation and credit tables in database backups: deleting records removes their
retry guarantees. `occurred_on` is a partner date and does not determine commit order.

Each operation uses an immediate SQLite transaction to coordinate writers across application
processes. Handled rejections roll back domain changes to a savepoint and commit the rejection
record. Unexpected exceptions roll back the entire current operation and abort the request with
`500`; earlier operations in the batch remain committed and can be replayed on retry.
