# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration reconstructs allocations without replaying operations or changing
cash and credit balances. Unattributed funding precedes durable funding; durable audit IDs order
recorded funding, regardless of operation dates. Historical operation results remain immutable.
Cash allocations retain current payment dispositions, while room and group totals are updated
atomically with each operation. Credit lots retain unrecovered clawback even when their current
shortfall is zero, so later refundable restorations can absorb it.
