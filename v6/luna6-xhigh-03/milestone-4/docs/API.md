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

Room responses also include `status`, `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. Group lodging, deposit due, and paid totals sum active rooms only. A cancelled
room reports zero due and paid amounts. Rooms remain in their original order.

## Room cancellation and cash corrections

`cancel_rooms` accepts `group_id`, `room_ids`, and the optional cancellation `refund_method`. Every
identifier must name a distinct active room in the group. It settles only those rooms and returns
`cancelled_room_ids` in the group's original order, along with `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. If no active room remains, the group becomes cancelled.

`reduce_cash_payment` accepts `payment_operation_id`, a positive `amount_cents`, and optional
`expected_revision`. It removes held cash from that payment in reverse room-allocation order and
reopens the active rooms' deposits. `operation_not_found`, `payment_not_reducible`,
`invalid_amount`, and `reduction_exceeds_held_cash` describe target and amount failures.

`charge_back_payment` accepts `payment_operation_id` and optional `expected_revision`. It moves all
remaining cash from that applied payment to charged-back cash, including amounts previously
refunded, retained, or converted to credit. Any amount already reduced stays reduced. Credit issued
from the payment is revoked where possible; credit still applied to active groups can create a
shortfall until it is consumed or returned.

Both correction operations return a durable operation result. Their target payment's original
stored result is never changed.

## Read one payment

`GET /api/v1/payments/:payment_operation_id` returns the current disposition of one durably
recorded, applied cash payment:

```json
{
  "data": {
    "payment_operation_id": "pay-17",
    "original_group_id": "group-81",
    "recorded_cents": 5000,
    "held_cents": 1000,
    "refunded_cents": 500,
    "retained_cents": 500,
    "converted_to_credit_cents": 1000,
    "reduced_cents": 500,
    "charged_back_cents": 1500
  }
}
```

The six disposition amounts sum to `recorded_cents`. A missing operation returns `404` with
`operation_not_found`; a record that is not an applied cash payment returns `422` with
`payment_not_reconcilable`.

## Read finance totals

`GET /api/v1/ledger`

The response starts with:

```json
{
  "data": {
    "cash_held_cents": 0,
    "cash_refunded_cents": 0,
    "cash_retained_cents": 0,
    "cash_converted_to_credit_cents": 0,
    "cash_reduced_cents": 0,
    "cash_charged_back_cents": 0,
    "credit_liability_cents": 0,
    "credit_shortfall_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash to
refunded, retained, or converted-to-credit principal. Unpaid deposit requirements are not cash and
never appear in these totals.

`cash_reduced_cents` and `cash_charged_back_cents` are current cumulative classifications of
recorded cash. Recorded cash reconciles to held, refunded, retained, converted, reduced, and
charged-back cash. `credit_shortfall_cents` reports charged-back credit entitlement still covered
by credit applied to active groups. Credit liability includes all available and actively applied
credit, including credit covered by a shortfall.
