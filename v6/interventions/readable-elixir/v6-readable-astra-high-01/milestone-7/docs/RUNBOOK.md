# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The period-close migration adds durable cutoffs and marks existing finance movements as ordinary
movements. Run `mix ecto.migrate` before starting the updated service against an existing database.
Closes publish the journal through their cutoff; subsequent operations only append entries after
that cutoff. Credit expiry is represented in the journal, so publishing and reading closed reports
require no scheduled job or daily snapshot generation.
