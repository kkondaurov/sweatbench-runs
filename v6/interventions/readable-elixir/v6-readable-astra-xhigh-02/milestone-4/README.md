# GroupStay

GroupStay records group reservations and their hotel deposits. It accepts ordered
partner operations to open, fund, reschedule, and cancel reservations, and exposes
group details, guest credit, and finance totals over a Phoenix JSON API.

Read the [product overview](docs/PRODUCT.md), [API contract](docs/API.md),
[operational rules](docs/requests/01-operational-core.md),
[cancellation economics](docs/requests/02-cancellation-economics.md),
[durable operations](docs/requests/03-durable-operations.md), and [runbook](docs/RUNBOOK.md).

## Development

```sh
mix setup
mix phx.server
```

The development service listens at `http://localhost:4000`; set `PORT` to choose
another port. Run the full suite with `mix test` and check formatting with
`mix format --check-formatted`.

To run a separate HTTP service in the test environment with a persistent database:

```sh
export MIX_ENV=test
export GROUP_STAY_DATABASE_PATH="$PWD/tmp/manual.db"
export PORT=4002
mix ecto.create
mix ecto.migrate
mix phx.server
```

Upgrade an existing database with `mix ecto.migrate` using the same environment
and database path as the service. Production uses `DATABASE_PATH` and requires
`SECRET_KEY_BASE`, as configured in `config/runtime.exs`.

## Implementation

`GroupStay.PartnerBatches` returns ordered outcomes. `GroupStay.Operations` validates
envelopes and owns durable submissions, exact retries, and the transaction boundary.
`GroupStay.Reservations` owns reservation persistence, revision checks, and cancellation
settlement. `GroupStay.Reservations.Booking` validates and prices booking details.
`CancellationPolicy` fixes terms at booking time. `GroupStay.HotelCredit` manages
credit lots and their contributions to group deposits; `GroupStay.Ledger` derives
cash balances and credit liability from a consistent database snapshot.
Controllers only handle HTTP input and response rendering.

Each operation with a usable identifier uses an immediate SQLite transaction. The
database acquires its write lock before the operation record or group is read, so
concurrent retries have at-most-once effects and revision checks are atomic.
The full submitted JSON and normalized JSON result commit with domain changes.
An operation's generated audit ID preserves first-commit order. Exact retries read
only that record; conflicts preserve it. A savepoint rolls back domain changes for
handled rejections while retaining their results, and batch processing continues.
Unexpected exceptions roll back the current transaction and abort the request.
A busy transaction start is retried up to three times;
the operation callback has not run at that point. Statement and commit errors are
never retried.

Rooms retain their input order. Deposits use integer arithmetic and round each
room separately. Cancellation clears the deposit requirement, preserves the
historical amounts paid by cash and credit, and settles each funding source.
Refundable credit returns to its original lot and expiry without another bonus.
Credit redeemed into an active deposit remains a liability even after that expiry;
an expired restoration is immediately removed from liability. Read dates filter
expiry on current balances and do not reconstruct historical accounting snapshots.
Unpaid requirements never count as cash. Group prices must fit SQLite's signed
64-bit integer storage; finance totals are summed with Elixir integers to preserve
precision across groups.

The suite includes HTTP contract tests, domain invariance checks for rejected
operations, migration and restart checks, fault injection, and concurrency tests
using separate connections and real commits.
