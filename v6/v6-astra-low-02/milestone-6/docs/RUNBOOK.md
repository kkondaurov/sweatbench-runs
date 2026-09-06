# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting uses the `finance_reporting` and `finance_entries` tables introduced by migration
`20260905000005`. Run migrations before serving the new release. Migration alone does not start
reporting: submit `start_finance_reporting` at the desired operational boundary. Back up these tables
with the rest of the SQLite database; inception, finance entries, domain changes, and operation audit
records commit together. No expiry scheduler is required: durable future expiry entries are adjusted
by funding operations and included by report reads. Reports remain open and may change when late
operations arrive.
