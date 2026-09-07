# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is enabled explicitly by the first applied `start_finance_reporting` operation,
not by deployment. Migrate before starting the service; the finance migration adds empty reporting
tables without rewriting existing accounts. Choose `starts_on` for the opening position and submit
the start operation at the intended processing boundary. Earlier committed operations become
opening balances regardless of their occurrence dates. Keep the finance opening and movement tables
with the domain tables and durable operation journal in database backups. Expiry is reported from
durable scheduled movements; it requires no timer or daily maintenance job.
