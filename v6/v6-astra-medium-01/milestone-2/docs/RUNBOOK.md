# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics release adds a migration that backfills each existing group's fixed policy
from its original booking date and copies its prior deposit funding to cash funding. Apply it with
`mix ecto.migrate` in the deployment environment before running the new code. Existing revisions and
completed cash settlements are preserved. Credit lots and active funding allocations are persisted
in SQLite; expiry is evaluated on reads and operations, so no expiry scheduler is required.
