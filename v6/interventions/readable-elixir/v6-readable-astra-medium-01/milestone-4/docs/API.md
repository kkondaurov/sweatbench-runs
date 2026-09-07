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

## Room accounting and payment corrections

Rooms additionally expose `status`, `lodging_total_cents`, `deposit_due_cents`,
`cash_paid_cents`, and `credit_paid_cents`. Room prices remain visible after cancellation;
the group's totals include only active rooms. Funding fills active rooms in original order.

`cancel_rooms` takes `group_id`, a nonempty array of distinct active `room_ids`, and optional
`refund_method` (`cash` by default or `hotel_credit`). It uses the group's fixed cancellation
policy. Its result includes `cancelled_room_ids` in booking order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`. Full cancellation settles all remaining
active rooms. Credit bonuses are rounded once on the selected rooms' combined cash.

`reduce_cash_payment` takes `payment_operation_id` and positive integer `amount_cents`.
It removes only that payment's held cash, starting with its last filled room. Its result includes
`payment_operation_id`, the derived `group_id`, `amount_cents`, `outstanding_deposit_cents`,
and `revision`. Settled cash cannot be reduced.

`charge_back_payment` takes `payment_operation_id` and reverses that payment's cash except
previous reductions. Its result includes `payment_operation_id`, the derived `group_id`,
`charged_back_cents`, `outstanding_deposit_cents`, and `revision`. It can address a cancelled
group. Converted credit entitlement is revoked from available credit first; spent entitlement
can create a shortfall without changing the groups funded by that credit.

All three operations use the common `operation_id` and `occurred_on` fields and accept
`expected_revision`. Corrections check the original payment group's revision. They use the
same durable retry contract as other operations. Original payment results remain unchanged.

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` with exactly:

- `payment_operation_id` and `original_group_id`;
- `recorded_cents`;
- `held_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`,
  `reduced_cents`, and `charged_back_cents`.

All amounts are present, including zero. The six dispositions sum to `recorded_cents`.
Missing records return `404` with `operation_not_found`; records other than applied cash
payments return `422` with `payment_not_reconcilable`.

The ledger adds `cash_reduced_cents`, `cash_charged_back_cents`, and `credit_shortfall_cents`.
Cash dispositions sum to all recorded cash, including pre-journal cash. Credit liability includes
credit funding active rooms, even when shortfalled. Restored credit absorbs unrecovered clawback
before becoming available or expiring. The `on` parameter evaluates expiry, not historical
accounting state.

Detailed validation codes and entitlement rules are specified in
[request 04](requests/04-room-accounting-and-payment-reductions.md).
