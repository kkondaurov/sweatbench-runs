# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

For a local checkout, run `mix setup`, then `mix phx.server`. Run `mix test` for the complete suite;
it creates and migrates the test database automatically. The suite covers HTTP contracts, atomic
rejections, concurrent writers, migration upgrades and rollbacks, and persistence across repository
restarts. Its isolated persistence databases are created under the repository's ignored `tmp/`
directory and removed after each test.

To use a separate test database and HTTP port:

```sh
export MIX_ENV=test
export GROUP_STAY_DATABASE_PATH="$PWD/tmp/group_stay.db"
export PORT=4100
mix ecto.create
mix ecto.migrate
mix phx.server
```

Migrate existing databases with `mix ecto.migrate` in the environment that owns the database before
starting the new server. Production uses `DATABASE_PATH` and requires `SECRET_KEY_BASE`; `PORT`
still selects its listener port. Releases also run pending migrations during application startup.

Each partner operation commits independently. SQLite immediate transactions protect revision and
balance checks across server processes. Writers within a node are serialized before entering SQLite
to keep waiting connections from blocking the native schedulers needed by the current writer.
Group and room records, including cancellation settlements, are persisted in SQLite; finance reads
derive their totals from a consistent database snapshot.
