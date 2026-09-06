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

Operations that address a group through another identifier — `reduce_cash_payment` and
`charge_back_payment` derive their group from the original payment — follow the same contract.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`
- `cash_paid_cents`
- `credit_paid_cents`

The lodging, due, paid, and outstanding totals describe the group's active rooms only. Each room
contains `room_id`, `nightly_rate_cents`, `status` (`active` or `cancelled`), `deposit_due_cents`,
`cash_paid_cents`, and `credit_paid_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Settle selected rooms

A `cancel_rooms` operation contains `group_id`, `room_ids`, and the same optional `refund_method`
used by full cancellation. It settles the allocated cash and credit of the selected rooms using the
same rules as `cancel_group`; a hotel-credit bonus is computed once on the selected rooms' combined
cash. All supplied room identifiers must identify distinct, active rooms in the group, otherwise the
operation is rejected with `invalid_rooms`. The applied result contains `group_id`,
`cancelled_room_ids` (in the group's original room order), `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. If no active rooms remain, the group becomes `cancelled`.

## Reduce recorded cash

A `reduce_cash_payment` operation contains `payment_operation_id`, `amount_cents`, and optional
`expected_revision`. It records a provider correction against one durably recorded, applied cash
payment. Only cash from that payment still held on active rooms can be reduced; held allocations
are removed in reverse fill order and the group's outstanding deposit reopens by the amount
removed. The applied result contains `payment_operation_id`, the derived `group_id`,
`amount_cents`, `outstanding_deposit_cents`, and `revision`.

Rejections use `operation_not_found`, `payment_not_reducible`, `invalid_amount`, and
`reduction_exceeds_held_cash`.

## Charge back a payment

A `charge_back_payment` operation contains `payment_operation_id` and optional `expected_revision`.
It reverses all cash from one durably recorded payment except any portion already recorded as
reduced, whether its group is active or cancelled. Rejections use `operation_not_found` and
`payment_not_chargeable`. The applied result contains `payment_operation_id`, the derived
`group_id`, `charged_back_cents`, `outstanding_deposit_cents`, and `revision`.

## Reconcile one payment

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, the response is:

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

The six disposition fields sum exactly to `recorded_cents`. A missing durable operation record
returns `404` as `{"error":{"code":"operation_not_found"}}`; a record that is not an applied cash
payment returns `422` as `{"error":{"code":"payment_not_reconcilable"}}`.

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
to either refunded or retained; reductions and chargebacks move it to reduced or charged-back cash.
`credit_shortfall_cents` is the current credit that chargebacks could not recover. Unpaid deposit
requirements are not cash and never appear in these totals.
