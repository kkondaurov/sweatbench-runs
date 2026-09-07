# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills each group's fixed policy from its original
`booked_on` date and copies its existing paid deposit into `cash_paid_cents`. It preserves room,
revision, and cash-entry history and adds the credit lot and allocation tables.

Credit expiry needs no scheduled job. Reads evaluate available lots on the requested date (UTC
today by default); operations use `occurred_on`. Applied allocations remain liabilities until
cancellation settles them, including after their source lot expires. Credit and reservation writes
share an immediate SQLite transaction so concurrent groups cannot spend the same guest balance.
