# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is enabled explicitly by `start_finance_reporting`. Use `close_finance_period`
to publish through a chosen `period_end_on`; no scheduler or calendar-month boundary is required.
Both operations use the partner batch endpoint and durable operation IDs. A new close must advance
the cutoff. Retrying the same submitted close returns its original result.

The period-close migration preserves existing inception and reporting entries. Apply it with
`mix ecto.migrate` before starting the new application. Published cutoffs and late-adjustment
classifications are stored in SQLite and survive restarts. After the first close, downgrading this
migration is refused because the older release could alter published reports.
