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
`POST /api/v1/partner-batches`, read bookings at `GET /api/v1/groups/:group_id`, read guest credit
at `GET /api/v1/guests/:guest_id/credit`, read finance totals at `GET /api/v1/ledger`, and retrieve
original operation results at `GET /api/v1/operations/:operation_id`.
Credit and ledger reads accept `?on=YYYY-MM-DD` to evaluate expiry at a chosen date.

```sh
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

The test suite includes HTTP contract tests through `GroupStayWeb.ConnCase`, plus tests using
independent SQLite connections for concurrent writes, transaction rollback, migrations, and
persistence across repository and application restarts. Those isolated databases are created under
`tmp/`.

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
SQLite transaction. It first checks the durable operation journal while holding the write lock.
An identical retry returns the original JSON result; a changed payload returns
`operation_id_conflict`. For new operations it resolves group existence and checks the revision
before validating the requested change. Handled rejections leave domain records unchanged and
commit their audit record. Unexpected exceptions roll back the current operation and abort the
request; earlier operations remain committed.

`Reservations.OperationRecord` retains each complete submission, its type, and its JSON result.
Decoded JSON equality ignores object key order while preserving array order and value types. The
generated integer record ID preserves first-commit order under SQLite's write lock. Results are
normalized to JSON before storage so first attempts, retries, and lookups agree on dates and keys.

`Reservations.Group` contains the booking and deposit transitions. Its embedded rooms preserve the
partner's original ordering. Prices use integer cents and per-room rounding; room rates may be
zero, while cash payments must be strictly positive. Individual lodging totals fit within SQLite's
signed 64-bit integer range.

`Reservations.CancellationPolicy` fixes terms from the booking date; only the refundable deadline
moves with arrival. `Reservations.CancellationSettlement` separates cash refunds, retentions, and
credit conversions from the restoration of previously applied credit.

`Reservations.CashEntry` preserves each payment and settlement with its partner operation ID and
date. Cancellation clears the current due and paid deposit balances, and transfers previously paid
cash to refunded, retained, or converted to credit. The lodging amount and rooms remain on the
cancelled group.

`Reservations.HotelCredit` owns credit issuance, ordered redemption, and restoration. Credit lots
keep their original expiry and bonus; immutable allocations record exactly which lots funded a
group. Expiry is paused while credit funds an active group. Cancellation restores the original lots
when refundable, or consumes the credit otherwise. Exhausted and expired lots remain stored for
funding history and possible restoration, while reads omit unavailable balances.

`Reservations.Ledger` reads cash movements, available credit, and credit in active deposits in one
database snapshot. It combines subtotals in Elixir to preserve exact totals across properties.

Idempotency begins with submissions first received by this release. Earlier accounting entries
remain intact and are not backfilled into the operation journal. The gateway starts a new operation
identifier namespace at deployment, as described in the runbook.
