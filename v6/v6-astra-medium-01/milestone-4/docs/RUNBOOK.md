# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills allocations without replaying partner operations or
changing durable results. Legacy funding is senior to recorded funding; durable commit order,
not operation dates, determines the latter's allocation order. Previously cancelled groups retain
their cash settlements while their active-room totals become zero. Apply migrations before serving
requests with the new code. This migration cannot be rolled back because partial settlements and
chargebacks cannot be represented by the earlier schema.
