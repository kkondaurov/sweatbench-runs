# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills allocations transactionally. Legacy
funding becomes an unattributed senior block (cash, then credit in original
consumption order). Applied durable funding follows in operation commit order,
using the retained type rather than business dates or result shapes. Existing
cash and credit balances, revisions, and operation records are preserved.
Previously settled durable payments also receive reconciliation dispositions.
The migration carries frozen schemas and arithmetic so future application code
changes cannot alter this upgrade.
