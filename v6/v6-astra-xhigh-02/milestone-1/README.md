# GroupStay

GroupStay records group reservations, deposits, and cancellation settlements for Northstar Hotels.
It is a Phoenix JSON API backed by SQLite. Payment providers handle the actual movement of money.

Run locally:

```sh
mix setup
mix phx.server
```

The service listens on port 4000 by default; set `PORT` to choose another port.
For an existing database, apply upgrades with `mix ecto.migrate` before starting the service.

The endpoints are:

- `POST /api/v1/partner-batches` — open, fund, reschedule, and cancel groups in array order.
- `GET /api/v1/groups/:group_id` — read a reservation and its current deposit totals.
- `GET /api/v1/ledger` — read cash held, refunded, and retained across properties.

Run the full test suite with `mix test`. It includes HTTP contract tests and tests using independent
SQLite connections for concurrent updates, committed transactions, migrations, and persistence.
Run `mix format --check-formatted` to check formatting.

See the [product overview](docs/PRODUCT.md), [API contract](docs/API.md),
[operational requirements](docs/requests/01-operational-core.md), and [runbook](docs/RUNBOOK.md).
