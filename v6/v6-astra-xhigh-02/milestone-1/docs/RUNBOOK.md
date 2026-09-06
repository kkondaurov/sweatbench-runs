# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

To migrate and serve a separate test database from the repository root:

```sh
MIX_ENV=test GROUP_STAY_DATABASE_PATH=./group_stay_http_test.db mix ecto.migrate
MIX_ENV=test GROUP_STAY_DATABASE_PATH=./group_stay_http_test.db PORT=4002 mix phx.server
```

Partner operations each run in a SQLite immediate transaction. The write lock covers reading the
group, checking its revision and balance, and committing its update. Each successful operation is
committed before the next operation starts; a rejection rolls back only its own transaction.
Native lock waits are brief, and a busy transaction start is retried for up to five seconds.
Retries occur only before an operation begins, so they cannot replay a payment or settlement.

Reservation rows retain room order and cancellation settlement amounts. Cancellation clears the
current deposit requirement and paid balance; refunded and retained cash remain persisted on the
cancelled group. The ledger sums these stored balances, so it remains available after a restart.
