# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills each existing group's policy from its original
`booked_on` and `rate_plan`, and copies its applied cash into `cash_paid_cents`. Existing revisions,
rooms, dates, and cancellation settlements are preserved. Run `mix ecto.migrate` before starting
the upgraded application against an existing database.

Credit lots and the allocations that record which lots funded a group are persisted in SQLite.
Expiry is evaluated during credit application and reads; no scheduled expiry job is required.
Use `on=YYYY-MM-DD` on credit and ledger reads for a reproducible expiry date. This parameter
evaluates current balances, rather than reconstructing a historical ledger.
