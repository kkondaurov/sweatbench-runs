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

## Daily finance reporting

Submit `start_finance_reporting` with the common operation fields and `starts_on` (an ISO 8601
calendar date). Its result contains only `operation_id`, `status`, and `starts_on`. The opening
position includes all state committed before this operation, including earlier operations in its
batch. Reporting can start once; another start returns `reporting_already_started`. Missing or
invalid `starts_on` returns `invalid_reporting_date`. Durable retry rules apply.

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns `{"data": <report>}`. The date is required;
missing or invalid values return `422` with `invalid_reporting_date`. Dates before inception, or
reads before reporting starts, return `404` with `report_not_available`.

The report contains `date`, `status: "open"`, property-ordered `cash` entries, and company-wide
`credit`. Cash entries expose `property_id`, `opening_held_cents`, `movements`, and
`closing_held_cents`. Cash movement fields are `received_cents`, `transferred_in_cents`,
`transferred_out_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`,
`reduced_cents`, and `charged_back_cents`. Properties are omitted only when all balances and
movements are zero. Credit exposes `opening_liability_cents`, `movements`, and
`closing_liability_cents`; its movement fields are `issued_cents`, `expired_cents`,
`consumed_cents`, `revoked_cents`, and `absorbed_cents`.

Movements are signed net amounts. Corrections follow the property's held or settled cash and can
reverse prior classifications. Post-inception operations post on the later of `occurred_on` and
`starts_on`; late submissions can change prior open reports. Unused credit expires the day after
`expires_on`, including days without operations. Reads never post entries or change domain state.
