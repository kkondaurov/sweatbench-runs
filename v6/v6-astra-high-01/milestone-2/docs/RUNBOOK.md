# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills policy versions from each group's original booking
date and copies existing paid deposits into the cash balance. Run `mix ecto.migrate` before serving
the new API. Credit lots and allocations are persisted in the same database as reservations;
include them in database backups. Credit expiry is evaluated by reads and operations, so no
scheduled expiry worker is required.
