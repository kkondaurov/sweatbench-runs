# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Durable operations begin with this release; the gateway must switch to its new identifier
namespace at deployment. Run `mix ecto.migrate` before serving requests. No historical operation
records are reconstructed. The `operations` table retains submitted JSON and original results;
its increasing `id` records first-commit order under SQLite's serialized write transactions.
Keep this table with the reservation and credit tables when backing up or restoring the database:
removing audit records would also remove their retry protection.
