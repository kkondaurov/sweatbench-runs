# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance period close adds an append-only `finance_period_closes` table and a `late_adjustment`
flag on finance journal entries. Run `mix ecto.migrate` before serving this release. Existing
reporting inception and journal entries are preserved; existing movements remain ordinary.

Closes commit with their durable partner-operation records. Published reports are reproduced from
the immutable journal, with subsequent writes constrained to the open period. No scheduler or
report-generation job is needed, including for credit expiry on days without partner operations.
