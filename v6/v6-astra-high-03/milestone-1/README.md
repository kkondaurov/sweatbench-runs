# GroupStay

GroupStay records group reservations, deposits, and cancellation settlements for Northstar Hotels.
The partner API supports ordered batches of `open_group`, `record_cash_payment`,
`reschedule_group`, and `cancel_group` operations.

Read the [product overview](docs/PRODUCT.md), [API contract](docs/API.md), and
[runtime requirements](docs/RUNBOOK.md) for the service's behavior.

## Development

```sh
mix setup
mix phx.server
```

The API is available at `http://localhost:4000/api/v1`:

- `POST /partner-batches`
- `GET /groups/:group_id`
- `GET /ledger`

Set `PORT` to choose another HTTP port. Run `mix ecto.migrate` when upgrading an existing database.

## Verification

```sh
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

Tests cover HTTP contracts, accounting and revision rules, concurrent database writers, and
persistence across repository restarts. Each operation uses a separate SQLite write transaction;
rejected operations preserve existing state and batch processing continues in order.

To run the HTTP service against a dedicated test database:

```sh
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test mix ecto.migrate
GROUP_STAY_DATABASE_PATH="$PWD/group_stay_http_test.db" MIX_ENV=test PORT=4002 mix phx.server
```
