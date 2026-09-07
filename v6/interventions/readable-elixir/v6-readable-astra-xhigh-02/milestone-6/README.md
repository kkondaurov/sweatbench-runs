# GroupStay

GroupStay records group reservations and their hotel deposits. It accepts ordered
partner operations to open, fund, reschedule, and cancel reservations, and exposes
group details, guest credit, payment statements, and finance totals over a Phoenix JSON API.
Partners can also cancel selected rooms, correct payments, and transfer held deposits between
active reservations for the same guest.

Read the [product overview](docs/PRODUCT.md), [API contract](docs/API.md),
[operational rules](docs/requests/01-operational-core.md),
[cancellation economics](docs/requests/02-cancellation-economics.md),
[durable operations](docs/requests/03-durable-operations.md),
[room accounting and payment corrections](docs/requests/04-room-accounting-and-payment-reductions.md),
[deposit transfers](docs/requests/05-deposit-transfers.md),
[daily finance reports](docs/requests/06-daily-finance-report.md), and [runbook](docs/RUNBOOK.md).

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

`GroupStay.Finance` captures an explicit reporting inception and reads daily reports.
Its journal records opening balances and signed cash and credit movements in the same
transaction as each operation and receipt. Domain mutations receive an explicit journal
context with the operation's posting date, clamped to inception. Cash follows its current
allocation or settlement property, including negative settlement classifications on chargeback.
Unused credit has scheduled expiry entries; redemption offsets those entries and refundable
restoration schedules the returned excess again. Already expired restorations and shortfall
absorption post immediately. Daily reports fold this durable history without changing lots,
allocations, or reporting state. Late operations can change earlier open reports.

`GroupStay.Accounting` owns room allocations and their creation order. Transfers draw the newest
allocations first and create destination allocations in that draw order, preserving payment and lot
identity. Partially moved allocations keep their original position at the source. Transfers leave
cash dispositions and credit liability unchanged. `GroupStay.Payments` tracks cash settlements by
payment and group, so chargebacks reclassify the accounts where transferred cash actually settled.
Corrections update each changed group's totals and revision once, while still guarding and returning
the revision of the original payment group. Payment statements remember transfer participation and
read their held cash breakdown in the same snapshot as their other dispositions.

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
room separately. Cancellation clears selected rooms' deposit requirements and funding allocations;
cash history remains in payment accounts and immutable operation receipts. Group totals include
only active rooms. Cash converted together receives one combined bonus, with payment entitlements
assigned in funding order using cumulative rounded totals.
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

The deposit-transfer migration preserves previous allocations, balances and receipts, and backfills
settlement locations from the original payment groups. An unused upgrade can be rolled back;
after an applied transfer, use a forward migration to preserve the new accounting history.
The finance migration initially leaves reporting disabled. Start it explicitly after upgrading;
once started, further schema changes must preserve its inception and journal with forward migrations.
