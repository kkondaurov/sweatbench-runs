# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The durable-operations release adds the `operations` table. Run `mix ecto.migrate` in the target
environment before serving the new release. The gateway must begin its new operation-ID namespace
at deployment; no retry records are reconstructed for earlier releases.

The table retains complete submissions in `payload`, string operation types in `type`, and original
JSON responses in `result`. Malformed types remain in the submitted payload. Ascending `id` is the
order of first commits: operation transactions acquire SQLite's writer before looking up an ID and
insert the audit row together with domain changes. Retries and conflicts do not insert rows. Keep
these records with the domain database when backing up or restoring; deleting them removes the
retry guarantee for those identifiers.
