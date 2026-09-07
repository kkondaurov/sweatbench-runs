# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Durable operations

Run `mix ecto.migrate` before starting the new release. The gateway starts a new operation-identifier
namespace for this release; the migration creates an empty `operation_records` table and preserves
existing reservations, cash entries, credit lots, and allocations. No historical results are inferred.

`operation_records` is both the retry store and the audit trail. It retains the full submitted JSON
in `payload`, its string type in `operation_type` (malformed types remain in the payload), and the
original JSON `result`. Order audit reads by `id` to get first commit order; neither `occurred_on` nor
`inserted_at` defines that order. Retries and conflicts do not create or update records.

Keep audit records with the domain tables in database backups. Removing a record removes its retry
guarantee. Application restarts need no cache warming or replay: outcomes are read from SQLite.
