# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Room accounting upgrade

Run `mix ecto.migrate` with the selected environment and database before starting this release.
Migration `20260905000003` creates room funding and credit entitlement history. It allocates
unattributed legacy cash first, then legacy credit in original consumption order, followed by
applied durable funding in commit order. It preserves cash balances, credit balances, revisions,
and stored operation results. Cancelled groups' lodging totals become zero to match active-room
reporting.

`room_funding` replaces `credit_allocations` for current credit provenance. The migration transfers
and clears the old allocation rows. Room settlement history cannot be represented by the old
aggregate schema, so this migration does not support a down migration.

Validate changes with `mix test` and `mix format --check-formatted`. The suite includes upgrades
from earlier database versions, concurrent retries and corrections, transaction fault rollback,
and repository/application restarts.
