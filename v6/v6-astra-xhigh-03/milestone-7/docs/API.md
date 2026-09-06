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

## Daily finance reporting and period close

Submit `start_finance_reporting` with `operation_id` and `starts_on` to capture the current
financial state as reporting's opening position. Read a day with
`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`. Missing or invalid dates return `422` with
`invalid_reporting_date`; dates before inception, or reads before reporting starts, return `404`
with `report_not_available`.

Submit `close_finance_period` to publish every reporting day through a cutoff:

```json
{
  "operation_id": "close-2026-10",
  "type": "close_finance_period",
  "period_end_on": "2026-10-31"
}
```

Reporting must have started. The cutoff must be on or after `starts_on` and strictly later than
the latest successful close; otherwise the operation returns `invalid_period`. Neither starting
nor closing reporting addresses a group or uses a revision guard. A successful close returns
exactly `operation_id`, `status: "applied"`, and `period_end_on`. Durable retries return the stored
result; reusing its identifier with a different payload returns `operation_id_conflict`.

Reports through the cutoff have `status: "closed"` and their `data` stays byte-for-byte stable,
including after later closes and restarts. Later days have `status: "open"`. New operations post
on the latest of `occurred_on`, `starts_on`, and the day after the cutoff observed when they commit.
Posting dates already assigned never move. Batch operations observe earlier closes in that batch.

Every report includes `late_adjustments`, with a `cash` array and a company-wide `credit` object.
Each late cash entry has `property_id` and `movements` with the same eight classifications as
ordinary cash movements. The late credit object has `issued_cents`, `expired_cents`,
`consumed_cents`, `revoked_cents`, and `absorbed_cents`, always including zero values. Only movements
pushed forward by a close appear here; inception clamping alone is ordinary. Cash entries are
ordered by `property_id`, omitting all-zero late entries. Signed reclassifications remain visible
even when their net balance effect is zero.

For each classification, add ordinary and late movements to obtain the day's total. Opening and
closing balances include both. Scheduled credit expiry remains on its expiry date when that date
is open; corrections to closed expiry figures appear in the open period. Group, room, ledger,
payment statement, and stored operation results retain their current-state meanings.
