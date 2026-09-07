# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting requires the finance-reporting migration, then an explicit
`start_finance_reporting` partner operation. Migration alone does not start reports
or reconstruct historical movements. The opening position includes all state
committed before that start operation, including legacy funding. Reporting entries
and inception are stored in SQLite and commit with the operation audit record;
include them in the same database backups. No scheduled worker is needed for expiry
reports: unused-credit expiry entries are scheduled and adjusted transactionally.
