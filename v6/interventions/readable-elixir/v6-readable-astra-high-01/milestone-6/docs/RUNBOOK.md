# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Daily finance reporting is enabled explicitly with the `start_finance_reporting` partner
operation. Deploying the migration alone does not start reporting or reconstruct old movements.
The inception position and journal are stored in SQLite and must be backed up with the rest of
the database. They commit atomically with partner receipts and financial state.

No scheduled job is needed for daily credit expiry. The journal records expiry dates and adjusts
them as credit is redeemed or restored; report reads only aggregate persisted entries. Reports
remain open to late postings and are never closed or advanced by a read.
