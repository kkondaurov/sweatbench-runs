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

Rooms also expose `status`, `lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`,
and `credit_paid_cents`. Group totals include active rooms only. Funding fills active rooms
in their original order.

- `cancel_rooms` accepts `group_id`, a nonempty array of distinct active `room_ids`, and
  optional `refund_method` (`cash` by default or `hotel_credit`). It returns
  `cancelled_room_ids` in original room order, settlement amounts, `group_id`, and `revision`.
- `reduce_cash_payment` accepts `payment_operation_id` and positive `amount_cents`.
  It removes only that payment's held cash, starting with its last room allocation.
- `charge_back_payment` accepts `payment_operation_id`. It reclassifies all unreduced cash
  from that payment and revokes any credit entitlement its converted principal created.

Both payment corrections derive their group from the original applied cash payment and accept
`expected_revision`. Their results include the payment identifier, derived `group_id`, resulting
`revision`, and `outstanding_deposit_cents`; reductions return `amount_cents`, and chargebacks
return `charged_back_cents`. All three operations follow durable retry semantics.

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` with exactly:
`payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`.
The six dispositions sum to recorded cash. Missing operations return `404`/`operation_not_found`;
other operation types or rejected payments return `422`/`payment_not_reconcilable`.

The ledger adds cumulative `cash_reduced_cents`, cumulative `cash_charged_back_cents`, and current
`credit_shortfall_cents`. Shortfall measures revoked credit entitlement still funding active
rooms. It does not remove that funding or advance those groups' revisions. Credit returned to its
original lot absorbs unrecovered clawback before any excess becomes available or expires.
