# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting uses the `finance_reporting` inception record and `finance_entries` journal,
created by migration `20260907000005`. Upgrading does not enable reporting automatically: submit
`start_finance_reporting` once the intended opening position has been recorded. Back up these
tables with the domain and operation tables; they commit atomically and survive service restarts.

No scheduled worker is needed for credit expiry reports. Availability changes journal their future
expiry adjustments during partner operations, and report reads are read-only database snapshots.
Reports remain open and can change when a later submission posts to an earlier date.
