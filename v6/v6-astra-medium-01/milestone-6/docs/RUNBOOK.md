# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is opt-in after migrations: submit one `start_finance_reporting` operation with
an agreed `starts_on`. Existing financial state becomes the opening position; prior submissions
are not replayed into movements. Back up the entire SQLite database so the reporting inception,
finance journal, domain accounting, and durable operation records remain consistent. Daily reports
remain open and can change when backdated operations arrive.
