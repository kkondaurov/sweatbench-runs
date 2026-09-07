# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Period close adds a durable cutoff to finance reporting and a late-adjustment flag
to journal entries. Run the migrations before starting the new release; existing
entries remain ordinary movements and existing reporting starts with no cutoff.
Close and journal writes use the same operation transaction and SQLite write lock.
Published reports are reconstructed from immutable entries, with all later writes
posting after the cutoff. No scheduler or per-day snapshot job is required.
