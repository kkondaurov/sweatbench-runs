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

## Start finance reporting

Submit `start_finance_reporting` through the partner batch endpoint with the common
`operation_id` and `occurred_on` fields and a required `starts_on` date. It has no group target
or revision guard. Its applied result contains exactly `operation_id`, `status: "applied"`,
and `starts_on`.

The first applied start captures the financial state immediately before it as the opening
position on `starts_on`. Earlier operations in the same batch are included in that opening;
later operations produce movements. This boundary uses processing order, regardless of the
earlier operations' dates. Missing or invalid `starts_on` is rejected with
`invalid_reporting_date`; another valid start is rejected with `reporting_already_started`.
The usual durable replay and conflict rules apply.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

Returns `{"data": <report>}` with `date`, `status: "open"`, property cash entries ordered by
`property_id`, and a company-wide `credit` object. Each entry contains its opening balance,
classified signed movements, and closing balance. Properties with zero opening, closing,
and all movement amounts are omitted. The complete response fields and balance equations
are specified in [the daily finance report contract](requests/06-daily-finance-report.md).

A missing or invalid date returns `422` with `invalid_reporting_date`. Before inception,
or for a date earlier than `starts_on`, it returns `404` with `report_not_available`.
Errors use the standard `{"error":{"code":"..."}}` envelope.

Operations post on the later of `occurred_on` and `starts_on`. Cash follows the property
holding or settling it, including transfers and later provider corrections. Unused credit
expires the day after `expires_on`; applied credit's expiry remains paused. Expiry is
reported even on days without operations. Reads never change state, and late submissions
can revise earlier open reports. Rejected operations and durable retries add no movements.

Unlike the ledger's expiry-only `on` filter, reports use posting dates to explain daily
changes from the captured opening position.
