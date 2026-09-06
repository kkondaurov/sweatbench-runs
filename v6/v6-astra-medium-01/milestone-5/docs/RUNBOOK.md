# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The deposit-transfer migration adds a shared allocation sequence and persistent payment-transfer
markers. Existing funding is ordered by the senior cash/credit block, then durable funding commit
order; balances and stored operation results are preserved. Run `mix ecto.migrate` before starting
the new release. Transfers cannot be represented by the previous schema, so this migration does
not support rollback to the previous release.
