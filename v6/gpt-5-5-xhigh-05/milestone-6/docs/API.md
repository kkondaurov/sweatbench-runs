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

`start_finance_reporting` enables finance reports from a supplied `starts_on` date. It does not
address a group and has no revision guard:

```json
{
  "operation_id": "finance-start-1",
  "type": "start_finance_reporting",
  "starts_on": "2026-11-01"
}
```

The first applied start operation returns exactly:

```json
{
  "operation_id": "finance-start-1",
  "status": "applied",
  "starts_on": "2026-11-01"
}
```

Invalid reporting dates are rejected with `invalid_reporting_date`. Once reporting has started, a
different start operation is rejected with `reporting_already_started`; a retry of the original
operation follows the durable idempotency rules.

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

The response is `{"data": <report>}`. Missing or invalid dates return `422` as
`{"error":{"code":"invalid_reporting_date"}}`. Before reporting has started, or before its
`starts_on` date, the endpoint returns `404` as `{"error":{"code":"report_not_available"}}`.

A report contains `date`, `status: "open"`, cash entries ordered by `property_id`, and one
company-wide credit entry:

```json
{
  "data": {
    "date": "2026-11-01",
    "status": "open",
    "cash": [
      {
        "property_id": "ams-canal",
        "opening_held_cents": 1000,
        "movements": {
          "received_cents": 500,
          "transferred_in_cents": 0,
          "transferred_out_cents": 0,
          "refunded_cents": 0,
          "retained_cents": 0,
          "converted_to_credit_cents": 0,
          "reduced_cents": 0,
          "charged_back_cents": 0
        },
        "closing_held_cents": 1500
      }
    ],
    "credit": {
      "opening_liability_cents": 0,
      "movements": {
        "issued_cents": 0,
        "expired_cents": 0,
        "consumed_cents": 0,
        "revoked_cents": 0,
        "absorbed_cents": 0
      },
      "closing_liability_cents": 0
    }
  }
}
```
