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

## Publish finance periods

Daily reporting begins with a `start_finance_reporting` operation containing `starts_on`.
`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns the daily cash movements by property
and company-wide credit movements. See [daily reporting](requests/06-daily-finance-report.md)
for the full report schema and inception rules.

Submit `close_finance_period` with the common `operation_id` and `occurred_on` fields and a
`period_end_on` date to publish all available reports through that date. This operation addresses
no group and ignores revision guards. Reporting must have started, and the cutoff must be at or
after `starts_on` and strictly later than every successful prior close; otherwise the operation
returns `invalid_period`. Its applied result contains exactly `operation_id`, `status: "applied"`,
and `period_end_on`. Durable retries return the original result.

Published reports have `status: "closed"` and their `data` remains unchanged. Later dates have
`status: "open"`. Finance effects submitted after a close post on the later of their original
reporting date and the first open day. Posting dates are fixed when committed, including within
a batch; a later close never moves existing entries.

Every daily report also contains `late_adjustments`, with a `cash` array of `{property_id,
movements}` objects and a company-wide `credit` movement object. These have the same movement
columns as ordinary cash and credit. Only movements moved forward by a close appear here. Cash
properties are sorted by `property_id`, with all-zero adjustments omitted; the credit object is
always present. Add ordinary and late amounts for each classification to obtain the day's total.
Opening and closing balances include both. Signed classifications remain visible even when their
net balance effect is zero. See [period close](requests/07-period-close.md) for examples.

Period close changes reporting only. Group and room funding, ledger totals, payment statements,
and stored operation results retain their current-state meanings.
