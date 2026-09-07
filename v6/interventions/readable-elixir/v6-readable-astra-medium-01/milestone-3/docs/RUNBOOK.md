# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` journal through an additive migration. Run
`mix ecto.migrate` before starting the new service. Existing groups and credit balances are left
intact; no historical operation outcomes are reconstructed. The gateway must begin its new
operation-identifier namespace at deployment.

Journal rows are part of the accounting database and must be preserved with its backups. Their
integer `id` records first-commit order under SQLite's serialized writer transactions. Retries and
identifier conflicts do not append rows. Deleting journal records would remove retry protection.
