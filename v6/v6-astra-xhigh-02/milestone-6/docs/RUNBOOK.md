# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting requires the finance-reporting migration and one applied
`start_finance_reporting` partner operation. Apply migrations before starting the upgraded service.
Migration alone does not enable reports or reconstruct historical movements. The start operation
durably captures the existing opening position; subsequent finance movements commit in the same
transaction as reservation changes and the operation audit record.

Reports remain open and can change when backdated operations arrive. Credit expiry is represented
by dated reporting entries, so no scheduled job or report-read side effect is required. Keep the
finance tables with the reservation and partner-operation tables in database backups; restarting
the service does not reset inception or regenerate movements.
