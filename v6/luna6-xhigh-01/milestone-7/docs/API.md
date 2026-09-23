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

### Finance reporting operations

Start reporting with `start_finance_reporting` and an ISO 8601 `starts_on` date. The first applied
start captures the opening cash and credit balances; later start operations are rejected with
`reporting_already_started`.

Close through a date with `close_finance_period` and an ISO 8601 `period_end_on` date. A close has no
group or revision guard. Reporting must have started, the cutoff must be on or after `starts_on`,
and each successful cutoff must be later than the previous one. An invalid cutoff is rejected with
`invalid_period`. The applied result contains exactly:

```json
{
  "operation_id": "close-2026-10",
  "status": "applied",
  "period_end_on": "2026-10-31"
}
```

Successful close results follow the same durable replay and operation-id conflict rules as other
partner operations.

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

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

The date must be valid and reporting must have started on or before it. Missing or invalid dates
return `422` with `invalid_reporting_date`; unavailable dates return `404` with
`report_not_available`. Reports through the latest closed cutoff return `status: "closed"` and keep
their `data` unchanged. Later reports return `status: "open"`.

Each report includes `late_adjustments`. Its `cash` entries use the same movement classifications
as the regular cash entries, and its company-wide `credit` object uses the same classifications as
the regular credit `movements` object. These values include only effects posted later because of a
close. Regular movement fields exclude those effects; add the corresponding late-adjustment values
to reconcile total movements and balances. Late cash entries are ordered by `property_id` and omit
properties whose classifications are all zero. The credit object is always present.
