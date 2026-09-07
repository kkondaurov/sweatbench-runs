# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Running the operational API

Run `mix ecto.migrate` before starting the service with `mix phx.server`. To run an
isolated HTTP instance in the test environment, use the same database path for both:

```sh
MIX_ENV=test GROUP_STAY_DATABASE_PATH=./group_stay_http_test.db mix ecto.migrate
MIX_ENV=test GROUP_STAY_DATABASE_PATH=./group_stay_http_test.db PORT=4100 mix phx.server
```

`mix test` creates and migrates its configured database automatically. The suite covers
the JSON endpoints using `GroupStayWeb.ConnCase`, plus concurrent updates and restart
persistence using separate SQLite files under the repository's ignored `tmp/` directory.

## Reservation accounting

Each operation commits independently. SQLite immediate transactions serialize writers
before revision checks, so another request cannot overwrite a change between reading
the revision and saving the reservation. Rejected domain operations perform no writes.

Room positions preserve the order supplied when a group is opened. Cancelling clears
the current deposit due and paid balances and stores the paid cash as either refunded
or retained on the group. The ledger totals those persisted balances; unpaid deposits
never contribute to cash totals. No in-memory state is needed to reconstruct a group
or the ledger after a restart.
