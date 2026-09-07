# GroupStay

GroupStay records group reservations and their hotel deposits. It accepts ordered
partner operations to open, fund, reschedule, and cancel reservations, and exposes
group details and cash totals over a Phoenix JSON API.

Read the [product overview](docs/PRODUCT.md), [API contract](docs/API.md),
[operational rules](docs/requests/01-operational-core.md), and [runbook](docs/RUNBOOK.md).

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

`GroupStay.PartnerBatches` validates operation envelopes and returns ordered
outcomes. `GroupStay.Reservations` owns persistence, revision checks, and cash
settlement. `GroupStay.Reservations.Booking` validates and prices booking details.
Controllers only handle HTTP input and response rendering.

Each operation uses an immediate SQLite transaction. The database acquires its
write lock before the group is read, so concurrent revision checks cannot both
apply to the same revision. A rejected operation rolls back independently, and
batch processing continues.

Rooms retain their input order. Deposits use integer arithmetic and round each
room separately. Cancellation clears the deposit requirement, preserves the
historical amount paid, and records its refunded or retained settlement. The
ledger derives totals from these persisted accounts; unpaid requirements never
count as cash. Group prices must fit SQLite's signed 64-bit integer storage;
finance totals are summed with Elixir integers to preserve precision across groups.

The suite includes HTTP contract tests, database invariance checks for rejected
operations, and concurrency tests using separate connections and real commits.
