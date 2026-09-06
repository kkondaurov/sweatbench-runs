# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance period close adds a migration to mark late finance movements; existing entries remain
ordinary movements. Run `mix ecto.migrate` in the target environment before starting the new
release. Successful close operations are the durable cutoff records. Reports are derived from
append-only finance entries, and later writes cannot post into closed dates. No scheduler or
background publishing job is required.
