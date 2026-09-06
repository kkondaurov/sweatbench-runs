# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Period close adds a `late_adjustment` column to finance entries through an Ecto migration; existing
entries remain ordinary movements. Successful close operations in the durable operation journal
establish the cutoff. Close and posting decisions share the operation transaction's SQLite writer
lock. Reports use fixed entries and require no close job or expiry scheduler.
