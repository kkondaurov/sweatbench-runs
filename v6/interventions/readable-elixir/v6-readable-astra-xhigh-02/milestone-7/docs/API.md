# Partner API

All endpoints are below `/api/v1` and exchange JSON. Authentication is handled upstream and is not
part of this application.

Dates use ISO 8601 calendar dates. Monetary amounts are integer cents. Identifiers are
partner-supplied strings and must be returned unchanged.

## Submit operations

`POST /api/v1/partner-batches`

```json
{
  "operations": [
    {
      "operation_id": "op-1001",
      "type": "open_group",
      "occurred_on": "2026-10-03",
      "group_id": "group-81",
      "guest_id": "guest-22",
      "property_id": "ams-canal",
      "arrival_on": "2026-12-10",
      "departure_on": "2026-12-13",
      "rate_plan": "flexible",
      "rooms": [
        {"room_id": "room-a", "nightly_rate_cents": 15000},
        {"room_id": "room-b", "nightly_rate_cents": 17500}
      ]
    }
  ]
}
```

Operations are processed in array order. An operation can observe changes made by an earlier
operation in the same batch. A rejected operation does not undo earlier successful operations and
does not stop later operations.

A syntactically valid batch returns `200` and one result per operation, in the same order:

```json
{
  "results": [
    {
      "operation_id": "op-1001",
      "status": "applied",
      "group_id": "group-81",
      "deposit_due_cents": 19500
    }
  ]
}
```

Rejected operations have `status: "rejected"` and a stable `code`. A body without an operations
array is an invalid batch and returns `422` as `{"error":{"code":"invalid_batch"}}`.

Every group has a positive integer `revision`. Opening a group creates revision `1`. Each later
applied operation addressed to that group increments its revision exactly once and returns the
resulting revision. This includes operations that derive their group from another identifier.
Rejected operations do not increment it.

An operation addressed to an existing group accepts an optional `expected_revision`. When present,
the operation is applied only if it equals the group's revision immediately before that operation.
Changes made by earlier operations in the same batch are visible. A mismatch is rejected before
other domain validation as:

```json
{
  "operation_id": "op-1002",
  "status": "rejected",
  "code": "stale_revision",
  "group_id": "group-81",
  "expected_revision": 1,
  "actual_revision": 2
}
```

Group existence is resolved first, so an operation naming a missing group still returns
`group_not_found`. Omitting `expected_revision` preserves the existing unconditional behavior.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Read finance totals

`GET /api/v1/ledger`

The response starts with:

```json
{
  "data": {
    "cash_held_cents": 0,
    "cash_refunded_cents": 0,
    "cash_retained_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

## Publish finance reports

After `start_finance_reporting` establishes `starts_on`, submit `close_finance_period`
through the partner batch endpoint:

```json
{
  "operation_id": "close-2026-11",
  "type": "close_finance_period",
  "occurred_on": "2026-12-02",
  "period_end_on": "2026-11-30"
}
```

The applied result contains exactly `operation_id`, `status: "applied"`, and
`period_end_on`. The cutoff must be on or after inception and strictly later than
any successful close; otherwise the operation returns `invalid_period`. Closing
before reporting starts or supplying a missing or invalid cutoff also returns
`invalid_period`. This operation has no group or revision guard and follows the
same durable retry and conflict rules as other operations.

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns `status: "closed"` for
available dates through the cutoff and `status: "open"` afterward. Closed report
data remains unchanged by later operations, closes, or restarts. Missing or invalid
report dates return `422` with `invalid_reporting_date`; dates before inception or
reads before reporting starts return `404` with `report_not_available`.

Every report includes `late_adjustments: {"cash": [], "credit": {...}}`. Each cash
adjustment contains `property_id` and all eight cash movement columns inside
`movements`; the credit object contains all five credit movement columns directly.
Cash adjustments are sorted by property and omit properties whose classifications
are all zero. Credit classifications are always present, including zeros.

Ordinary movements and late adjustments are separate: add their corresponding
classifications to get the day's total movements. Both contribute to balances.
Signed reversals remain visible even when their net balance effect is zero.
An operation submitted after a close posts on the latest of `occurred_on`,
`starts_on`, and the day after the cutoff. Only movements deferred by a close are
late adjustments. Scheduled credit expiry retains its date when still in the open
period; later offsets to a closed expiry appear in the open period instead.

See the [daily report contract](requests/06-daily-finance-report.md) for the complete
cash and credit shapes and the [period-close rules](requests/07-period-close.md).
