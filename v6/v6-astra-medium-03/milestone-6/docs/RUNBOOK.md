# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting tables are created by the migrations. Migration alone does not start reporting:
the partner must submit `start_finance_reporting` to establish its durable opening position.
Opening positions and movements commit with operation audit records and survive restarts.
Credit expiry is represented by dated movements; no scheduler or report-read side effect is needed.
