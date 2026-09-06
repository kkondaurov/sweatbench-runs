# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is enabled explicitly by submitting `start_finance_reporting` after migrations
have run. Choose `starts_on` as the first reporting date; the operation captures the financial state
at processing time and cannot be replaced by another start. Keep the original operation identifier
for safe retries. The migration preserves existing domain and operation records and leaves reporting
disabled until this operation is applied.

The opening position and finance postings live in SQLite alongside the domain and durable operation
records and must be backed up together. Credit expiry needs no scheduled job: expiry postings are
stored and adjusted when credit availability changes. Daily report reads are read-only. All reports
remain open and may change when a late operation posts to an earlier date.
