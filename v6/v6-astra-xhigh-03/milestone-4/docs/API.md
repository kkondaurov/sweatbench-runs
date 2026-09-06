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
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Rooms retain their original order.
Cancelled rooms retain their original lodging price, have zero due and paid amounts, and remain in
the response with `status: "cancelled"`. Group lodging, due, paid, and outstanding totals count only
active rooms. Groups also expose `cash_paid_cents`, `credit_paid_cents`, the fixed `policy_version`,
and `refundable_until`.

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

`cash_held_cents` is cash currently applied to active rooms. Cancellation moves it to refunded,
retained, or `cash_converted_to_credit_cents`. Unpaid deposit requirements are not cash.
The response also includes cumulative `cash_reduced_cents` and `cash_charged_back_cents`, and current
`credit_liability_cents` and `credit_shortfall_cents`. All fields are present, including zero values.
Chargebacks reclassify a payment's held, refunded, retained, and converted cash; reduced cash remains
reduced. Total recorded cash equals the sum of these six cash dispositions.

Credit liability includes available, unexpired credit and credit applied to active rooms. Shortfall
is the sum, per lot, of the lesser of unrecovered clawback and credit still applied to active rooms.
Both the ledger and guest-credit reads accept `on=YYYY-MM-DD` to evaluate expiry; omission uses the
current UTC date.

## Cancel selected rooms

`cancel_rooms` supplies `operation_id`, `occurred_on`, `group_id`, a nonempty `room_ids` array, and
optional `expected_revision` and `refund_method` (`cash` by default, or `hotel_credit`). Every selected
room must be distinct and active, or the entire operation is rejected with `invalid_rooms`.

The applied result contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`. The group's fixed cancellation policy applies.
A hotel-credit bonus is calculated once on the selected rooms' combined cash. Applied credit returns
to its original lots on refundable cancellation, absorbing unrecovered clawback before any remainder
becomes available or expires. Non-refundable cancellation consumes applied credit.

Other rooms keep their funding. Cancelling the last active room cancels the group. `cancel_group`
settles all remaining active rooms under the same rules.

## Correct a cash payment

`reduce_cash_payment` supplies `operation_id`, `occurred_on`, `payment_operation_id`, `amount_cents`,
and optional `expected_revision`. It removes held cash from that specific durable, applied cash
payment in reverse room-fill order and reopens outstanding deposit. Settled cash cannot be reduced.
The applied result contains `payment_operation_id`, the derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`.

A missing target returns `operation_not_found`; a non-payment, rejected payment, or payment with no
held cash returns `payment_not_reducible`. An unusable amount returns `invalid_amount`. A positive
amount above the remaining held cash returns `reduction_exceeds_held_cash`.

`charge_back_payment` supplies `operation_id`, `occurred_on`, `payment_operation_id`, and optional
`expected_revision`. It charges back every cash disposition except prior reductions, including cash
from cancelled groups. Converted cash also revokes its share of issued credit, taking remaining
credit first and recording any unrecovered clawback. It does not change groups funded by that credit.
The applied result contains `payment_operation_id`, the derived `group_id`, `charged_back_cents`,
`outstanding_deposit_cents`, and `revision`. A missing target returns `operation_not_found`; a
non-payment, rejected payment, fully reduced payment, or already charged-back payment returns
`payment_not_chargeable`.

Both corrections check and increment only the original payment group's revision. The original
payment result stays unchanged. All new operations follow the durable retry rules: equivalent
payloads replay the original result, including rejections; a changed payload under the same
`operation_id` returns `operation_id_conflict`.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id`

For a durable, applied cash payment, the response contains exactly:

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

The six current dispositions sum to `recorded_cents`. Reading a statement does not change state.
A missing durable record returns `404` with `operation_not_found`. An existing record that is not an
applied cash payment returns `422` with `payment_not_reconcilable`. Legacy funding without a durable
operation identifier cannot be addressed by this endpoint or by payment corrections.
