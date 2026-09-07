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

Submit `start_finance_reporting` with the common `operation_id`, `type`, and `occurred_on`
fields plus `starts_on: "YYYY-MM-DD"`. Its first applied result contains exactly
`operation_id`, `status: "applied"`, and `starts_on`. The committed financial position immediately
before this operation becomes the opening position. Another start is rejected with
`reporting_already_started`; invalid or missing `starts_on` uses `invalid_reporting_date`.
The usual durable replay and conflict rules apply.

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns `{"data": <report>}` with `date`,
`status: "open"`, property-ordered `cash`, and company-wide `credit`. Cash rows contain
`property_id`, `opening_held_cents`, `closing_held_cents`, and `movements` with
`received_cents`, `transferred_in_cents`, `transferred_out_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`.
Credit contains `opening_liability_cents`, `closing_liability_cents`, and `movements` with
`issued_cents`, `expired_cents`, `consumed_cents`, `revoked_cents`, and `absorbed_cents`.
All movement columns are always present. Properties with zero opening, closing, and every
movement are omitted.

Movements are signed net amounts. Corrections follow cash to its holding or settlement property.
Posting uses the later of `occurred_on` and `starts_on`, so later submissions may change earlier
open reports. Available credit expires the day after its inclusive expiry date, including days
with no submissions. Report reads do not change state.

Missing or invalid `date` returns `422` with `invalid_reporting_date`. Reporting not yet started,
or a date before inception, returns `404` with `report_not_available`.
