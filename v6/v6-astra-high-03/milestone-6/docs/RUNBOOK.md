# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Finance reporting inception

Run `mix ecto.migrate` before serving this release. The finance migration preserves existing
accounting and creates empty reporting tables; it does not start reporting automatically.

Submit `start_finance_reporting` with the chosen `starts_on` through the partner batch API to
establish the opening position. All operations committed before that operation contribute to
the opening state, regardless of their dates. Reporting can be started only once; keep the start
operation's identifier and payload for safe retries.

Read `/api/v1/finance/daily-report?date=YYYY-MM-DD` to reconcile a day. Reports remain open to late
postings. No scheduled expiry job or report-generation job is needed: durable dated entries include
credit expiry and report reads do not write to the database. Reporting entries, opening positions,
domain changes, and operation results use the same SQLite database and transaction boundaries.
