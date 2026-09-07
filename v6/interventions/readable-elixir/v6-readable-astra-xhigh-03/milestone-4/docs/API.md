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

Every room contains `room_id`, `nightly_rate_cents`, `status`, `lodging_total_cents`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Room order never changes.
Cash and credit fill active rooms in that order. Cancelled rooms retain their agreed nightly rate
and lodging price; their current due and paid balances are zero. All group totals sum active rooms
only, including `lodging_total_cents`.

Groups also include `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and `refundable_until`.
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

`cash_held_cents` is cash currently applied to active rooms. Cancellation settles only the selected
rooms' cash, moving it to refunded, retained, or converted to credit. Reductions remove held cash;
chargebacks reclassify all of a payment's cash except prior reductions. Total recorded cash equals
the sum of those six cash dispositions. Unpaid requirements never enter cash totals.

`credit_liability_cents` includes unexpired available credit and all credit applied to active rooms,
including any shortfall. `credit_shortfall_cents` sums each lot's unrecovered clawback capped at
that lot's credit still applied to active rooms. Returning credit absorbs unrecovered clawback before
any excess becomes available or expires. Nonrefundable credit consumption reduces applied credit
and therefore its current shortfall.

The optional `on=YYYY-MM-DD` query evaluates expiry at that date; its default is the current UTC date.
It does not replay historical transactions.


## Cancel selected rooms

Submit `cancel_rooms` through the batch endpoint with `group_id`, a nonempty `room_ids` array,
`occurred_on`, and an optional `refund_method` (`cash` by default, or `hotel_credit`).
`expected_revision` follows the usual group revision contract.

Every supplied identifier must name a distinct active room; otherwise the entire operation is
rejected with `invalid_rooms`. Refundability uses the group's fixed cancellation policy and current
arrival date. Hotel credit on a nonrefundable cancellation is rejected with
`refund_method_not_available`. Refundable credit funding returns to its original lots; only the
selected rooms' combined cash receives the 10% credit bonus.

The applied result includes `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`. Other rooms remain unchanged. Cancelling the
last active room cancels the group; `cancel_group` settles all remaining active rooms.

## Correct a recorded cash payment

Submit `reduce_cash_payment` with `payment_operation_id`, positive integer `amount_cents`,
`occurred_on`, and optional `expected_revision`. The payment must have a durable, applied cash-payment
record. Only its cash still held on active rooms can be reduced, removing the last filled portion
first. Other payments and settled cash are unchanged.

The result includes `payment_operation_id`, the derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Errors are `operation_not_found`, `payment_not_reducible`,
`invalid_amount`, and `reduction_exceeds_held_cash`. A payment with no held cash is not reducible.

Submit `charge_back_payment` with `payment_operation_id`, `occurred_on`, and optional
`expected_revision` to reverse the payment's entire amount except prior reductions. Held cash is
removed; refunded, retained, and converted portions become charged-back cash. This does not reissue
or undo historical refunds. Credit entitlement created by converted cash is revoked from remaining
lot balances first, with any unrecovered amount tracked on each lot.

The result includes `payment_operation_id`, the derived `group_id`, `charged_back_cents`,
`outstanding_deposit_cents`, and `revision`. A missing record yields `operation_not_found`; any other
unusable target, fully reduced payment, or already charged-back payment yields
`payment_not_chargeable`. The original payment's group can be active or cancelled.

Both operations check the original payment group's revision before other domain validation and
increment only that group. Chargebacks leave groups funded by affected credit unchanged. Original
payment results remain immutable, and all new operations obey the durable retry contract.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id` returns current cash dispositions:

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

These are exactly the returned fields, including zero values. The six dispositions sum to
`recorded_cents`; reads never change state. Missing durable records return `404` with
`operation_not_found`. Records that are not applied cash payments return `422` with
`payment_not_reconcilable`. Funding before the durable journal has no targetable identifier.

## Durable operation results

`GET /api/v1/operations/:operation_id` returns `{"data": <original result>}` or `404` with
`operation_not_found`. Repeating an operation with equivalent JSON returns that exact result,
including original revisions and rejections. Object key order is ignored; array order and value
types matter. A different payload under the same identifier yields `operation_id_conflict`.
Unexpected server faults roll back the current operation without remembering a result and return
`500`; earlier operations in the batch remain committed.
