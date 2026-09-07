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

## Finance reporting and period close

Submit `start_finance_reporting` with `operation_id` and `starts_on` to capture the opening
financial position. Read a day with `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`.
The report includes cash by property and company-wide hotel-credit liability; see the
[daily report contract](requests/06-daily-finance-report.md) for its movement columns.

Submit `close_finance_period` with `operation_id` and `period_end_on` to publish all available
reports through that date. Reporting must have started, the cutoff must be on or after `starts_on`,
and each new cutoff must be strictly later than the last successful close. Otherwise the operation
returns `invalid_period`. Neither reporting operation addresses a group or uses revision guards.

An applied close returns exactly:

```json
{"operation_id":"close-1","status":"applied","period_end_on":"2026-10-31"}
```

Close operations use the same durable replay and conflict rules as other partner operations.
Closed daily reports return `status: "closed"` and their `data` remains unchanged. Reports after
the cutoff return `status: "open"`.

After a close, financial operations post on the latest of `occurred_on`, `starts_on`, and the day
after the current cutoff. The chosen date stays fixed. Every report includes `late_adjustments`
with a `cash` array and a `credit` movement object. Movements shifted forward by a close appear in
this block; other movements appear in the ordinary movement blocks. Sum both blocks for each
classification when reconciling opening and closing balances. Cash adjustments are ordered by
`property_id` and omit all-zero properties; the credit object always includes every column.
See the [period close contract](requests/07-period-close.md) for the complete shape.
