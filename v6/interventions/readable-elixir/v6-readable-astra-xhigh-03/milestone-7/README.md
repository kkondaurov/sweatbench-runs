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
original operation results at `GET /api/v1/operations/:operation_id`. Current payment statements
are available at `GET /api/v1/payments/:payment_operation_id`.
Credit and ledger reads accept `?on=YYYY-MM-DD` to evaluate expiry at a chosen date.
After a `start_finance_reporting` operation captures the opening position, daily reports are
available at `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`.
`close_finance_period` publishes reports through its `period_end_on` cutoff. Subsequent backdated
effects post on the first open day and appear in the report's `late_adjustments` block.

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

`Reservations.RoomAccounting` fills active rooms in their original order and derives group totals
from those rooms. Partial cancellation clears only selected rooms' balances, preserving their
agreed rates and lodging prices. `cancel_group` settles the remaining active rooms.

`Reservations.CashPayments` owns payment provenance and current dispositions in `CashAllocation`.
`reduce_cash_payment` removes the target payment's held allocations in reverse creation order
across all groups. `charge_back_payment` also reclassifies its settled portions and revokes
converted credit entitlement.
`CashEntry` keeps the original accounting facts, recording corrections as additional entries.
Payment statements report current allocation balances without altering the immutable operation
journal.

`Reservations.DepositTransfers` moves applied cash and credit between a guest's active groups.
`AllocationOrder` gives both funding kinds one creation order under the transaction's write lock.
Transfers draw the newest source portions first and create destination portions in that draw order,
preserving payment and credit-lot provenance. They split current allocation amounts while leaving
the original cash entries, credit redemptions, operation results, and all ledger totals intact.
Payment statements permanently include `held_by_group` once a payment participates in a transfer.
Transfers advance both groups; corrections advance the original payment group and each group
whose held cash changes, once each. Credit clawbacks leave credit-funded groups' revisions intact.

`Reservations.HotelCredit` owns issuance, ordered redemption, restoration, and clawbacks.
`RoomCreditAllocation` splits each immutable redemption across rooms and tracks which portions
remain active. Credit lots keep their original expiry; expiry pauses while credit funds active rooms.
Refundable settlement restores those portions, while nonrefundable settlement consumes them.

`CreditEntitlement` partitions each issued lot by contributing payment using differences of rounded
running totals in funding order. Spending remains fungible within the lot. Chargebacks revoke
remaining credit first and track unrecovered clawback on the lot. Restoration absorbs that amount
before making an excess available or allowing it to expire. Current shortfall is capped at credit
still funding active rooms; that credit remains part of the liability.

`Reservations.Ledger` reads cash movements, available credit, applied room credit, and shortfalls in
one database snapshot. It sums in Elixir to preserve exact cents even when cumulative recorded cash
exceeds SQLite's integer range. Payment statement reads likewise use a consistent transaction.

`GroupStay.Finance` captures reporting inception and records immutable `Finance.Entry` amounts
inside the same transaction as each applied operation. Opening cash is captured per group and
opening credit per lot and active allocation, including legacy funding and shortfalls. Cash
movements use the property where each allocation is held or settled. Replays bypass posting, and
failed transactions roll back reporting with domain changes.

Credit issuance schedules expiry of unused liability. Redemption offsets scheduled expiry;
restoration resumes it at the original expiry or the return's posting date, whichever is later.
Revocation of already expired unused credit has no further liability effect. Shortfall absorption
and nonrefundable consumption are separate movements. These signed expiry contributions handle
late submissions without a background job or rewriting prior entries.

`Finance.DailyReport` projects entries through the requested date in a read transaction, summing
exact cents in Elixir. Open reports can change with later submissions. `Finance.PeriodClose`
records each advancing publication cutoff under the same write lock as partner operations.
`Finance.Posting` floors new posting dates at inception and the first open day, recording whether
the close moved the date. Future scheduled expiry keeps its natural date; corrections to a closed
expiry appear on the first open day. Both ordinary and late movements contribute to balances.
A backdated revocation of credit whose expiry was already published reports the expiry reversal
and revocation together, preserving both classifications without reducing liability twice.

Closed reports need no daily snapshots: immutable entries and the posting floor prevent any new
contribution through a published cutoff. The HTTP presenter orders JSON fields explicitly so the
published bytes also survive application restarts. Reads use one database snapshot and never
materialize expiry or publication. The ledger remains a current-state view with date-based expiry;
it does not become a historical report.

The period-close migration preserves existing reporting entries as ordinary movements. Once a
period has been published, it refuses a downgrade that would discard the cutoff while retaining
the successful operation's replay result.

Idempotency begins with submissions first received by this release. Earlier accounting entries
remain intact and are not backfilled into the operation journal. The gateway starts a new operation
identifier namespace at deployment, as described in the runbook.

The room-accounting migration allocates earlier funding without changing cash or credit balances.
Unattributed cash and original credit redemptions form a senior block. Durably recorded funding
follows in journal commit order, classified by retained operation type. Existing settled payments
also receive current dispositions and conversion entitlements so they can be reconciled or charged
back after upgrading. Migration code uses the earlier storage layout directly, independently of
application schemas that will evolve in later releases.

The deposit-transfer migration interleaves the earlier cash and credit allocations using durable
funding commit order, preceded by each group's senior block. It does not change existing balances
or revisions. Once a transfer has applied, the migration refuses a downgrade to a release that
cannot account for funding across groups.
