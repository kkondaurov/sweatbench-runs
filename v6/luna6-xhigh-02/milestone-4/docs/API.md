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

Each room contains `room_id`, `nightly_rate_cents`, `lodging_total_cents`, `status`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Group lodging, due, and paid totals
include active rooms only; a cancelled room keeps its original lodging and deposit requirement but
has no current cash or credit funding. A missing group returns
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
to either refunded or retained. `cash_reduced_cents` and `cash_charged_back_cents` report cash
removed through provider corrections. `cash_converted_to_credit_cents` reports converted cash
principal. `credit_liability_cents` includes available credit and credit applied to active groups;
`credit_shortfall_cents` reports applied credit covered by a chargeback clawback. Unpaid deposit
requirements are not cash and never appear in these totals.

## Settling rooms

`cancel_rooms` contains `group_id`, `room_ids`, and the same `refund_method` option as
`cancel_group`. Every identifier must name a distinct active room in that group. It returns
`group_id`, `cancelled_room_ids`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and
`revision`. The returned room identifiers follow the group's original room order. When the last
active room is cancelled, the group becomes `cancelled`.

## Reducing or charging back cash

`reduce_cash_payment` contains `payment_operation_id`, a positive `amount_cents`, and optional
`expected_revision`. It removes held cash from that payment in reverse room fill order. The result
contains `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and
`revision`. Rejections include `operation_not_found`, `payment_not_reducible`, `invalid_amount`,
and `reduction_exceeds_held_cash`.

`charge_back_payment` contains `payment_operation_id` and optional `expected_revision`. It moves all
remaining cash from that payment to charged-back cash, including cash previously refunded, retained,
or converted to credit. Its result contains `payment_operation_id`, `group_id`,
`charged_back_cents`, `outstanding_deposit_cents`, and `revision`. Rejections include
`operation_not_found` and `payment_not_chargeable`.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id` returns the current disposition of a durably recorded,
applied cash payment. The response contains `payment_operation_id`, `original_group_id`,
`recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`,
`converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. The disposition amounts sum
to the recorded amount. An unknown identifier returns `404` with `operation_not_found`; a stored
operation that is not an applied cash payment returns `422` with `payment_not_reconcilable`.
