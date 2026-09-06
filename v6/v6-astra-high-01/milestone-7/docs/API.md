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

Submit `start_finance_reporting` with `starts_on` to establish the opening position. Read daily
figures with `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`; the response is
`{"data": <report>}`. Invalid dates return `422` with `invalid_reporting_date`. Reports before
inception return `404` with `report_not_available`. See [daily finance reporting](requests/06-daily-finance-report.md)
for the cash and credit movement classifications.

Submit `close_finance_period` with `period_end_on` to publish all available reports through that
date. Reporting must already have started, and the cutoff must be at least `starts_on` and strictly
after any previous successful cutoff. Invalid or missing cutoffs are rejected with `invalid_period`.
This operation has no group or revision guard. Its applied result contains exactly:

```json
{"operation_id":"close-17","status":"applied","period_end_on":"2026-11-30"}
```

Closes follow the durable operation replay and conflict rules. Published reports have
`status: "closed"` and stable JSON data, including across restarts. Later days have `status: "open"`.
Subsequent financial operations post on the latest of `occurred_on`, `starts_on`, and the day after
the most recent cutoff when the operation commits. A later close never changes an existing posting.

Every daily report includes `late_adjustments`, with a `cash` array of `{property_id, movements}`
and a `credit` object containing all five credit movement columns. These contain only movements
whose posting date was advanced by a close. Cash rows are sorted by property and omit all-zero
movements. The ordinary `movements` fields exclude these adjustments; balances include both.
Signed reclassifications remain visible even when their combined balance effect is zero.
Scheduled credit expiry in an open period remains ordinary movement on its expiry date.
