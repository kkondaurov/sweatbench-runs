# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting uses the `finance_reporting` inception row and `finance_movements` journal.
Run the new migration before accepting traffic, then submit `start_finance_reporting` when
controllers are ready to establish the opening position. Migration alone does not enable reports.
Back up these tables together with the domain and durable operation records. Report reads are
side-effect free; no daily expiry job is required, and historical reports remain open to late postings.
