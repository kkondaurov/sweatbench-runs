# GroupStay

GroupStay is Northstar Hotels' internal group-reservation deposit API. It records partner-reported
cash payments and cancellation settlements; it does not charge cards or initiate refunds.

Read the [product](docs/PRODUCT.md), [API](docs/API.md), and [runbook](docs/RUNBOOK.md) for the service
contract. [TASK.md](TASK.md) identifies the current product request.

## Development

```sh
mix setup
mix phx.server
```

The service defaults to port 4000 in development; `PORT` overrides it. Submit operations to
`POST /api/v1/partner-batches`, read bookings at `GET /api/v1/groups/:group_id`, and read cash totals
at `GET /api/v1/ledger`.

```sh
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

The test suite includes HTTP contract tests through `GroupStayWeb.ConnCase`, plus tests using
independent SQLite connections for concurrent writes, transaction rollback, migrations, and
persistence across repository restarts. Those isolated databases are created under `tmp/`.

To run the HTTP service against a separate test database:

```sh
mkdir -p tmp
MIX_ENV=test GROUP_STAY_DATABASE_PATH=tmp/manual-test.db mix ecto.create
MIX_ENV=test GROUP_STAY_DATABASE_PATH=tmp/manual-test.db mix ecto.migrate
MIX_ENV=test GROUP_STAY_DATABASE_PATH=tmp/manual-test.db PORT=4002 mix phx.server
```

Apply new Ecto migrations with `mix ecto.migrate` when upgrading an existing database. Production
uses `DATABASE_PATH` and `SECRET_KEY_BASE`, as configured in `config/runtime.exs`.

## Implementation

`GroupStay.Reservations` processes operations sequentially, committing each in its own immediate
SQLite transaction. It resolves group existence and checks the revision while holding the write
lock, before validating the requested change. Rejected operations leave all records unchanged.

`Reservations.Group` contains the booking and deposit rules. Its embedded rooms preserve the
partner's original ordering. Prices use integer cents and per-room rounding; room rates may be
zero, while cash payments must be strictly positive. Individual lodging totals fit within SQLite's
signed 64-bit integer range.

`Reservations.CashEntry` preserves each payment and settlement with its partner operation ID and
date. Cancellation clears the current due and paid deposit balances, and transfers previously paid
cash to refunded or retained. The lodging amount and rooms remain on the cancelled group. The
ledger aggregates committed accounting entries, excluding unpaid deposit requirements.

Operation IDs identify outcomes and accounting entries. The current API does not specify replay
deduplication; each submitted operation is evaluated against the current group state.
