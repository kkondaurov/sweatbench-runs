# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Local verification

Run `mix setup` for development, then `mix phx.server`. Run `mix test` for the full
suite; its alias creates the test database and runs pending migrations. The suite
includes API tests through `GroupStayWeb.ConnCase` and concurrency tests using
independent SQLite connections in temporary databases under the repository's `tmp/`.

To run the HTTP service against a separate test database:

```sh
MIX_ENV=test GROUP_STAY_DATABASE_PATH="$PWD/tmp/manual.db" mix ecto.create
MIX_ENV=test GROUP_STAY_DATABASE_PATH="$PWD/tmp/manual.db" mix ecto.migrate
MIX_ENV=test GROUP_STAY_DATABASE_PATH="$PWD/tmp/manual.db" PORT=4100 mix phx.server
```

Create the `tmp/` directory first if it does not exist. Test sandbox ownership is
enabled by the test helper only, so a server started with `MIX_ENV=test` can handle
normal HTTP requests. Restarting the server keeps bookings and finance entries in
the selected database.

Each partner operation uses an immediate SQLite transaction to serialize revision
checks with writes. A batch deliberately has no enclosing transaction: an applied
operation remains committed when a later operation is rejected. Cash entries are
written in the same transaction as the corresponding group balance and revision.
