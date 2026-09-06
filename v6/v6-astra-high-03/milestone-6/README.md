# GroupStay

GroupStay records group reservations, deposits, and cancellation settlements for Northstar Hotels.
The partner API supports ordered batches of `open_group`, `record_cash_payment`,
`apply_hotel_credit`, `reschedule_group`, `cancel_rooms`, `cancel_group`,
`reduce_cash_payment`, `charge_back_payment`, and `transfer_deposit` operations. Room allocations
and payment statements track cash through settlement, provider corrections, and credit clawbacks.
Transfers move held cash and hotel credit between active groups for the same guest, preserving
payment and credit-lot provenance. Payment corrections follow cash across groups and advance
every affected group's revision.
Flexible cancellation policies are fixed at booking, and refundable cancellations can issue hotel
credit with a 10% bonus for later reservations.
The `start_finance_reporting` operation establishes a durable opening position. Daily finance
reports show cash movements by property and company-wide credit liability, including automatic expiry.

Read the [product overview](docs/PRODUCT.md), [API contract](docs/API.md), and
[runtime requirements](docs/RUNBOOK.md) for the service's behavior.

## Development

```sh
mix setup
mix phx.server
```

The API is available at `http://localhost:4000/api/v1`:

- `POST /partner-batches`
- `GET /operations/:operation_id`
- `GET /payments/:payment_operation_id`
- `GET /groups/:group_id`
- `GET /ledger`
- `GET /guests/:guest_id/credit`
- `GET /finance/daily-report?date=YYYY-MM-DD`

Credit and ledger reads accept `?on=YYYY-MM-DD` to evaluate expiry, defaulting to today in UTC.
Daily reports require a date and are available from the reporting inception date. Late submissions
can revise open reports; report reads never change accounting state.

Set `PORT` to choose another HTTP port. Run `mix ecto.migrate` when upgrading an existing database.

## Verification

```sh
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

Tests cover HTTP contracts, accounting and revision rules, concurrent database writers,
room allocation order, partial settlements, reductions, chargebacks, payment reconciliation,
credit issuance, redemption, expiry, restoration and clawbacks, deposit transfers, migration upgrades,
daily finance inception, posting dates, signed corrections, expiry, and persistence across application
and repository restarts. Each operation uses a separate SQLite write transaction;
handled rejections preserve domain state and batch processing continues in order. Applied and
rejected results are durably remembered by operation identifier, together with their complete
submissions and commit order. Exact retries return the original result; changed payloads conflict.
Unexpected faults roll back the current operation and return `500`, allowing safe batch retries.

To run the HTTP service against a dedicated test database:

```sh
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test mix ecto.migrate
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test PORT=4002 mix phx.server
```
