# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Deploying durable operations

Run `mix ecto.migrate` before serving the new release. The migration adds `operation_records` and
its unique operation-identifier index without changing existing reservations, cash entries, credit
lots, or allocations. Coordinate the gateway's new operation-identifier namespace with deployment;
records for submissions made under earlier releases are intentionally not reconstructed.

The operation journal is part of the SQLite database. Preserve it with the accounting tables in
backups and restores, and do not prune records while their identifiers may be retried. Its generated
integer `id` records first-commit order because each operation holds SQLite's write lock until its
domain changes and audit record commit. Order audit reads by `id`, not partner dates or timestamps.
The `submission` column retains the complete JSON object, `type` retains a submitted string type,
and `result` retains the exact JSON outcome. Malformed types are preserved in `submission`.

After a `500` or a lost response, the gateway can retry the entire batch with its original payloads
and identifiers. Earlier committed operations replay their stored outcomes; the failed operation
is evaluated again. A handled rejection is permanent for that identifier. Corrected operations
must use a new identifier. Support can retrieve the original outcome through
`GET /api/v1/operations/:operation_id`.
