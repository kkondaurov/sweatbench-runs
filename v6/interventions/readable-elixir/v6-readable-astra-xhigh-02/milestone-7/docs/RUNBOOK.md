# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The period-close migration preserves existing finance inception and journal history;
it does not automatically start reporting or close a period. Submit
`close_finance_period` through the partner API to publish through an inclusive date.
Once any period is closed, schema changes must use forward migrations to preserve
published reports and late adjustments. Downgrading the period-close migration is
supported only before the first successful close.
