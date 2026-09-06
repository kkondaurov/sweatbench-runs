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

- `POST /api/v1/partner-batches` — open, fund, transfer deposits, reschedule, cancel groups or selected rooms, reduce cash payments, and record chargebacks in array order.
- `GET /api/v1/operations/:operation_id` — read the original result of a remembered partner operation.
- `GET /api/v1/payments/:payment_operation_id` — reconcile the current disposition of a recorded cash payment.
- `GET /api/v1/groups/:group_id` — read a reservation and its room and deposit totals.
- `GET /api/v1/guests/:guest_id/credit` — read available hotel credit and its expiry dates.
- `GET /api/v1/ledger` — read cash settlements and credit liability across properties.
- `GET /api/v1/finance/daily-report?date=YYYY-MM-DD` — reconcile daily cash movements by property and company credit liability.

Credit and ledger reads accept `on=YYYY-MM-DD` to evaluate expiry, defaulting to today's UTC date.
Daily reports require a date and become available after a `start_finance_reporting` partner
operation with `starts_on`. The start freezes the opening position; later operations and automatic
credit expiry contribute dated movements. A `close_finance_period` operation with `period_end_on`
publishes reports through that date. Closed reports remain unchanged; subsequent operations dated
in the closed period post on the first open day in `late_adjustments`. Add ordinary and late
movement columns to reconcile opening and closing balances. Each later close must advance the cutoff.

Partner operations are durably idempotent by `operation_id`. An exact retry returns its original
applied or rejected result; changing the payload under the same identifier returns
`operation_id_conflict`. Submissions and results commit atomically with reservation changes.

Run the full test suite with `mix test`. It includes HTTP contract tests and tests using independent
SQLite connections for concurrent updates, committed transactions, migrations, and persistence.
Run `mix format --check-formatted` to check formatting.

See the [product overview](docs/PRODUCT.md), [API contract](docs/API.md),
[operational requirements](docs/requests/01-operational-core.md),
[cancellation economics](docs/requests/02-cancellation-economics.md),
[durable operations](docs/requests/03-durable-operations.md),
[room accounting and payment corrections](docs/requests/04-room-accounting-and-payment-reductions.md),
[deposit transfers](docs/requests/05-deposit-transfers.md),
[daily finance reporting](docs/requests/06-daily-finance-report.md),
[finance period close](docs/requests/07-period-close.md),
and [runbook](docs/RUNBOOK.md).
