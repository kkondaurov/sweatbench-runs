# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is enabled explicitly through `start_finance_reporting` after running
`mix ecto.migrate` for the deployment environment. The migration preserves existing financial
state; the start operation captures that state as its opening position. Reporting starts once per
database and survives application and database-process restarts.

Daily reports need no scheduler or expiry job. Opening positions and signed entries are stored in
SQLite with their partner operations; report reads include scheduled credit expiry without writing
to the database. Reports remain open and may change when backdated operations arrive.
