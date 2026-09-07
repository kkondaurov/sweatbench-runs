# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills held room slices and payment dispositions without replaying
partner operations or changing their stored results. It allocates each active group's legacy cash
and credit before durable funding in commit order. Existing credit lot balances and group revisions
are preserved. Run migrations before starting the new application against an older database.

Room balances and group totals are persisted read snapshots. Payment dispositions, room funding,
credit allocations, lot clawbacks, and the operation result commit together in the existing immediate
transaction. Finance and payment reads calculate current classifications without performing repairs
or expiry writes. Never edit an original operation result to reflect a later correction.
