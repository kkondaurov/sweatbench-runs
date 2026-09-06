# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Room-accounting upgrade

Run `mix ecto.migrate` before starting the new application against an older database. The
room-accounting migration builds room funding allocations and payment dispositions in its
migration transaction, preserving durable submissions, results, commit order, and aggregate
cash and credit balances. Cancelled groups' lodging totals become zero under the new active-room
reporting contract.

Existing active funding without a durable record becomes a senior, unattributed block: cash
first, then credit lots in their original consumption order. Applied durable cash payments and
credit applications follow in record commit order. Legacy cash cannot be addressed through the
payment statement or correction operations. Historical durable payments remain reconcilable,
including those already settled before the upgrade.
