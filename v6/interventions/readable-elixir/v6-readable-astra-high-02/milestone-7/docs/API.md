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

Submit `start_finance_reporting` with `starts_on` to capture the current opening position.
Then read `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`. See
[the daily report contract](requests/06-daily-finance-report.md) for the cash and credit columns.

Submit `close_finance_period` through the partner batch endpoint to publish reports through an
inclusive cutoff:

```json
{
  "operation_id": "close-2026-11",
  "type": "close_finance_period",
  "occurred_on": "2026-12-02",
  "period_end_on": "2026-11-30"
}
```

Reporting must have started. The cutoff must be on or after `starts_on` and strictly after any
previous successful cutoff; otherwise the result is rejected with `invalid_period`. Missing or
invalid `period_end_on` also returns `invalid_period`. No group or revision guard is required.
Success contains exactly `operation_id`, `status: "applied"`, and `period_end_on`. Applied and
rejected closes follow the same durable retry and identifier-conflict rules as other operations.

Reports through the cutoff return `status: "closed"` and their `data` value remains stable.
Later reports return `status: "open"`. Subsequent operations post on the latest of `occurred_on`,
`starts_on`, and the first day after the cutoff in effect when they commit. Later closes do not
move previously posted entries. Batch order determines which cutoff each operation observes.

Every successful report includes `late_adjustments`, with a `cash` array and a `credit` object.
Cash rows contain `property_id` and `movements` using the usual cash classifications; credit uses
the usual credit classifications directly. Cash rows are ordered by property and omit all-zero
movements; credit always contains every classification, including zeros. These values contain
only movements whose posting date was moved by a close. The ordinary `movements` fields exclude
them. Add ordinary and late values per classification to reconcile opening and closing balances.
Signed reclassifications remain visible even when they have no net balance effect.

Scheduled credit expiry remains on its existing date when that date is still open. Corrections
to an expiry already published post into the open period without changing the closed report.
Closing affects reporting only; group, ledger, payment, and operation reads keep their existing
meanings. See [the period close contract](requests/07-period-close.md) for the full response shape.
