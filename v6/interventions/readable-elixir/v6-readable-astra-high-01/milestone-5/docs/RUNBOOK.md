# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The deposit-transfer migration adds a shared cash/credit allocation sequence and durable payment
transfer participation. It recovers the order of existing funding from receipts and room occupancy
without changing balances, revisions, credit lots, or stored results. Run migrations before starting
application instances from the new release; old instances must stop writing before the upgrade so
all subsequent allocations receive the shared sequence.
