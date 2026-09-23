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

Rooms also expose `lodging_total_cents`, `status` (`active` or `cancelled`),
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Group lodging, deposit due,
deposit paid, cash paid, credit paid, and outstanding totals include active rooms only. Cancelling a
room clears its current due and applied funding; the room remains in the response with its original
lodging amount and `cancelled` status.

## Cancel rooms

`cancel_rooms` accepts `group_id`, a non-empty `room_ids` array, `occurred_on`, and the same optional
`refund_method` (`cash` or `hotel_credit`) as `cancel_group`. The identifiers must be distinct and
must all refer to active rooms in the group. Otherwise the operation is rejected with
`invalid_rooms` and makes no changes.

Selected rooms use the group's cancellation policy. Cash and credit applied to those rooms are
settled using the selected refund method; unpaid deposit for those rooms is no longer due. Other
rooms and their funding remain unchanged. The result contains `group_id`, `cancelled_room_ids`,
`refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`. The cancelled room IDs are
returned in original room order. If no active rooms remain, the group becomes cancelled.
`cancel_group` settles only the remaining active rooms.

## Reduce or charge back recorded cash

`reduce_cash_payment` accepts `payment_operation_id`, a positive `amount_cents`, and optional
`expected_revision`. It can remove only cash from that applied payment which is still held on active
rooms. Reductions apply in reverse room-allocation order and reopen the deposit by the amount
removed. A reduction may equal the payment's full remaining held amount. The result contains
`payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.

`charge_back_payment` accepts `payment_operation_id` and optional `expected_revision`. It charges
back every remaining disposition of that applied cash payment except amounts already reduced. Held
cash is removed from active rooms, and refunded, retained, or converted cash is reclassified as
charged back. A chargeback can target a payment even after its group is cancelled. The result
contains `payment_operation_id`, `group_id`, `charged_back_cents`, `outstanding_deposit_cents`, and
`revision`.

Both operations derive the addressed group from the original payment and increment only that
group's revision. Their own operation results are durable and idempotent. The original payment
result is never rewritten.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id` returns the current cash disposition for a durably
recorded, applied cash payment. Its `data` object contains exactly:

```json
{
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
```

The six disposition amounts always sum to `recorded_cents`. An unknown identifier returns `404`
with `operation_not_found`; a durable record which is not an applied cash payment returns `422`
with `payment_not_reconcilable`.

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
totals. The ledger also includes cumulative `cash_reduced_cents` and `cash_charged_back_cents`.
Recorded cash equals held, refunded, retained, converted to credit, reduced, and charged-back cash.
`credit_shortfall_cents` reports revoked credit entitlement that is still applied to active groups;
credit liability continues to include that applied credit until settlement removes it.
