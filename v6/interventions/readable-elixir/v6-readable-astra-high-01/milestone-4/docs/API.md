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

Each room contains `room_id`, `nightly_rate_cents`, `status`, `lodging_total_cents`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Rooms retain their original
order, including cancelled rooms. Cancellation clears that room's current amounts. Group totals
sum active rooms only. Funding fills active room deposits in original order; later funding fills
any capacity reopened by a payment correction.

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
    "cash_retained_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted to hotel credit. Unpaid deposit requirements are not cash and never appear in these
totals.

## Settle selected rooms

`cancel_rooms` accepts `group_id`, a nonempty `room_ids` array of distinct active room identifiers,
and optional `refund_method` (`cash`, the default, or `hotel_credit`). It uses the group's fixed
cancellation policy and settles only the selected rooms' funding. Its result includes
`group_id`, `cancelled_room_ids` in booking order, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. The credit bonus is rounded once on the combined cash.
When the last active room is cancelled the group becomes cancelled. `cancel_group` settles all
remaining active rooms.

## Correct recorded payments

`reduce_cash_payment` accepts `payment_operation_id` and a positive integer `amount_cents`.
It removes only the target payment's cash still held on active rooms, in reverse fill order.
Its result includes `payment_operation_id`, the derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`.

`charge_back_payment` accepts `payment_operation_id`. It reclassifies all of that payment's cash
except previously reduced cash as charged back, reopening held deposits and revoking any credit
entitlement created by converted cash. Historical refunds are not reissued. Its result includes
`payment_operation_id`, the derived `group_id`, `charged_back_cents`,
`outstanding_deposit_cents`, and `revision`. Cancelled groups also accept chargebacks.

Both operations use the original payment group's optional `expected_revision` and increment only
that group's revision. As with every operation, supply `operation_id`, `type`, and `occurred_on`.
Their receipts are durable; the original payment receipt remains unchanged.

A missing target returns `operation_not_found`. An ineligible target returns
`payment_not_reducible` or `payment_not_chargeable`. A reduction with an unusable amount returns
`invalid_amount`; a positive amount above the remaining held portion returns
`reduction_exceeds_held_cash` when some held cash remains.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` for an applied,
durably recorded cash payment. A statement has exactly these fields:

- `payment_operation_id` and `original_group_id`;
- `recorded_cents`;
- `held_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`,
  `reduced_cents`, and `charged_back_cents`.

All monetary fields are always present, and the six dispositions sum to `recorded_cents`.
A missing receipt returns `404` with `operation_not_found`; any other kind of receipt returns
`422` with `payment_not_reconcilable`. Legacy funding without a durable payment receipt cannot
be addressed through payment operations or this endpoint.

## Extended finance totals

The ledger also includes `cash_converted_to_credit_cents`, `cash_reduced_cents`,
`cash_charged_back_cents`, `credit_liability_cents`, and `credit_shortfall_cents`.
Recorded cash equals the sum of held, refunded, retained, converted, reduced, and charged-back cash.

Credit liability includes available unexpired credit and credit applied to active rooms. A
chargeback first revokes unspent entitlement from its original lot. Any unrecovered entitlement,
capped by that lot's credit still applied to active rooms, contributes to current credit shortfall.
Returned credit absorbs unrecovered clawback before expiry is evaluated. A chargeback does not
revise groups using the affected credit. The ledger's optional `on=YYYY-MM-DD` projects expiry as of
that date, defaulting to the current UTC date; it is not a historical snapshot.
