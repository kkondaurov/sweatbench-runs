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
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

These totals include active rooms only. Each room contains `room_id`, `nightly_rate_cents`,
`status`, `lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. Cancelled rooms retain their original prices and have no held funding.
Cash and credit fill active rooms in original room order, in operation-processing order.
A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

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
to refunded, retained, or converted cash. Provider corrections classify cash as reduced or charged
back. The six dispositions sum to all recorded cash. Unpaid deposit requirements are not cash and
never appear in these totals.

The ledger accepts `on=YYYY-MM-DD` to evaluate available credit expiry, defaulting to the current
UTC date. Applied credit remains a liability while held on active rooms. A current shortfall is
revoked entitlement that remains covered by applied credit, calculated separately for each lot.
These reads do not change state or replay historical balances.

## Settle selected rooms

Submit `cancel_rooms` with the common `operation_id`, `occurred_on`, and `group_id` fields,
a nonempty `room_ids` array, and optional `expected_revision` and `refund_method` (`cash` by default,
or `hotel_credit`). Identifiers must be distinct active rooms in that group; an invalid selection
returns `invalid_rooms` without settling any room.

The fixed group policy and cancellation date determine whether cash is refundable and credit can
be restored. Hotel credit is available only for refundable cancellation. The cash bonus is rounded
once for the combined selected cash; restored credit never receives another bonus.

The result contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`, in addition to the common result fields.
The group becomes cancelled when its last active room is settled. `cancel_group` settles all
remaining active rooms and keeps its existing result fields.

## Correct a recorded cash payment

Payment corrections supply `payment_operation_id`, `operation_id`, `type`, `occurred_on`, and
optional `expected_revision`. They derive the addressed group from the original cash payment.

| Operation type | Additional input | Behavior | Result fields beyond the common fields |
| --- | --- | --- | --- |
| `reduce_cash_payment` | Positive integer `amount_cents` | Removes only the target payment's held cash, in reverse fill order. | `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, `revision` |
| `charge_back_payment` | None | Reclassifies all of the payment except prior reductions, removes held funding, and revokes credit it created. | `payment_operation_id`, `group_id`, `charged_back_cents`, `outstanding_deposit_cents`, `revision` |

Both operations return `operation_not_found` for an unknown durable identifier. A reduction returns
`payment_not_reducible` for a noncash or rejected target or one with no held cash;
`invalid_amount` for an unusable amount on a reducible payment; and
`reduction_exceeds_held_cash` when the positive amount exceeds what remains held.
A chargeback returns `payment_not_chargeable` for a noncash or rejected target, a fully reduced
payment, or one already charged back. Chargebacks are permitted on cancelled groups.

A chargeback changes only the original payment group's revision. Groups funded by the affected
credit keep their state and revision. The clawback removes available entitlement from each lot
first. Unrecovered entitlement absorbs future restorations before excess credit becomes available
or expires. Historical refunds and retentions are reclassified without recording another transfer.

Both corrections and room cancellations use the existing durable retry contract. The original
payment receipt remains immutable, including its original outstanding balance and revision.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id` returns exactly:

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

All amounts are always present. The six current dispositions sum to the recorded amount.
An unknown durable operation returns `404` with code `operation_not_found`; an existing operation
that is not an applied cash payment returns `422` with code `payment_not_reconcilable`.
Unattributed funding from before durable operations has no payment endpoint identifier.
