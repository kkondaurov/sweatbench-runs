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

Operations that derive their group from a payment (`reduce_cash_payment`,
`charge_back_payment`) address the original payment's group for revision checking. A
`cancel_rooms` operation settles the selected rooms under the same date, policy, refund
method, bonus, and restoration rules as a full cancellation, rejecting the complete
operation with `invalid_rooms` unless every supplied room identifier names a distinct,
active room. `reduce_cash_payment` removes held cash of one durably recorded payment in
reverse fill order (`operation_not_found`, `payment_not_reducible`, `invalid_amount`,
`reduction_exceeds_held_cash`), and `charge_back_payment` reclassifies every remaining
disposition of one payment (`payment_not_chargeable`), revoking the hotel-credit
entitlement it created.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

The totals describe the group's active rooms only; a cancelled room's deposit is no longer
due and its funding is settled. Each room contains:

- `room_id`
- `nightly_rate_cents`
- `status` (`active` or `cancelled`)
- `deposit_due_cents`
- `cash_paid_cents`
- `credit_paid_cents`

Cash and credit fund active room deposits in the rooms' original order, filling one room's
deposit before moving to the next. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, the current disposition of every cent it
recorded:

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

The six disposition fields sum exactly to `recorded_cents` and agree with the group, room,
and ledger views. Funding from before durable operation records has no payment identifier
and cannot be read through this endpoint. Return `404` as
`{"error":{"code":"operation_not_found"}}` when no durable operation record exists, and
`422` as `{"error":{"code":"payment_not_reconcilable"}}` when the record is not an applied
cash payment.

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

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained, and payment corrections move it to reduced or charged back.
Recorded cash equals held, refunded, retained, converted, reduced, and charged-back cash.
`credit_shortfall_cents` is the credit clawed back from charged-back payments that could not be
recovered from unspent lots and is still funding active groups. Unpaid deposit requirements are
not cash and never appear in these totals.
