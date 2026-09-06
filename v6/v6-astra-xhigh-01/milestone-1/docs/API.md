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

Each operation requires `operation_id`, `type`, `occurred_on`, and `group_id`. Identifiers must be
nonempty strings. Unknown types or missing operation fields produce `invalid_operation`; malformed
individual operations do not prevent the remaining operations from running. An empty operations
array is valid. `open_group` ignores `expected_revision`.

The supported operations are:

| Type | Additional fields | Applied result fields (besides operation ID, status, group ID, and revision) |
| --- | --- | --- |
| `open_group` | `guest_id`, `property_id`, `arrival_on`, `departure_on`, `rate_plan`, `rooms` | `deposit_due_cents` |
| `record_cash_payment` | `amount_cents` | `amount_cents`, `outstanding_deposit_cents` |
| `reschedule_group` | `new_arrival_on` | `new_arrival_on`, `new_departure_on` |
| `cancel_group` | None | `refunded_cents`, `retained_cents` |

Rate plans are `flexible` (20% deposit, rounded separately for each room) and `advance_purchase`
(full lodging deposit). Room rates are nonnegative integer cents; cash payments must be positive
integer cents and cannot exceed the outstanding deposit. Individual amounts and group lodging
totals must fit in a signed 64-bit integer. A stay must contain at least one night and one room,
with room IDs unique within the group.

Rescheduling preserves the length and price of the stay and requires an arrival after `occurred_on`.
Cancellation refunds paid cash for flexible groups at least 14 days before their current arrival;
otherwise it retains the paid cash. Unpaid deposits never become refunds or retained cash.

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

An opened group is `active`. Cancellation changes its status to `cancelled` and clears the deposit
due, paid, and outstanding totals because the deposit has been settled. Its lodging total, dates,
identifiers, and rooms remain available. Settled cash remains in the finance totals. Payments,
reschedules, and further cancellations require an active group.

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
