# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting requires the finance-reporting migration and an explicit
`start_finance_reporting` partner operation. Migration alone does not start
reporting. The inception and movements are stored in SQLite and commit with
their partner operation; no scheduler or daily expiry job is required.
All daily reports remain open and can change when backdated operations arrive.
