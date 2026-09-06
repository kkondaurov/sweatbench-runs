# GroupStay

GroupStay records group reservations, deposits, and cancellation settlements for Northstar Hotels.
The partner API supports ordered batches of `open_group`, `record_cash_payment`,
`apply_hotel_credit`, `reschedule_group`, and `cancel_group` operations.
Flexible cancellation policies are fixed at booking, and refundable cancellations can issue hotel
credit with a 10% bonus for later reservations.

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
- `GET /groups/:group_id`
- `GET /ledger`
- `GET /guests/:guest_id/credit`

Credit and ledger reads accept `?on=YYYY-MM-DD` to evaluate expiry, defaulting to today in UTC.

Set `PORT` to choose another HTTP port. Run `mix ecto.migrate` when upgrading an existing database.

## Verification

```sh
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

Tests cover HTTP contracts, accounting and revision rules, concurrent database writers,
credit issuance, redemption, expiry and restoration, migration upgrades, and persistence across
repository restarts. Each operation uses a separate SQLite write transaction;
handled rejections preserve domain state and batch processing continues in order. Applied and
rejected results are durably remembered by operation identifier, together with their complete
submissions and commit order. Exact retries return the original result; changed payloads conflict.
Unexpected faults roll back the current operation and return `500`, allowing safe batch retries.

To run the HTTP service against a dedicated test database:

```sh
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test mix ecto.migrate
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test PORT=4002 mix phx.server
```
