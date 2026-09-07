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

After applying the finance migration, submit one `start_finance_reporting` operation through
`POST /api/v1/partner-batches`, with a stable `operation_id`, the common `occurred_on` date, and the
chosen `starts_on` date. Reporting remains unavailable until this operation commits. Existing
allocations and credit balances become the opening position, including funding without old audit
records. Operations earlier in the same batch are included in that opening.

Read a day through `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`. No expiry job or report
generation job is needed. Unused credit expiry is scheduled in the journal, and reads never change
financial state. Reports remain open to later submissions with earlier posting dates.

Back up the whole SQLite database so inception, journal, domain accounts, and durable receipts
remain consistent. An unused finance migration can be rolled back. Once reporting starts, use
forward migrations to preserve reporting history.
