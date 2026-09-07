# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations migration adds an `operations` journal without changing
existing reservations or credit. The gateway must start its new operation-ID
namespace on deployment; historical results are not reconstructed. Do not purge
or modify this journal: it supplies both the retry guarantee and the submission
audit. Its integer `id` records first-commit order, and `payload` retains the full
submitted JSON. Include it with the domain tables in database backups.
