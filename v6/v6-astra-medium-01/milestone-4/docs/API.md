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

Rooms also expose `status`, `lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. Group totals sum active rooms only. Cancelled rooms keep their quoted lodging
and deposit amounts, with zero held cash and credit. Funding fills active rooms in original room
order; a correction can reopen space that subsequent funding fills.

The batch endpoint additionally accepts:

- `cancel_rooms`: `group_id`, a nonempty `room_ids` array of distinct active room identifiers,
  and optional `refund_method` (`cash` by default or `hotel_credit`). The settlement uses the group's
  fixed cancellation policy. Its result includes `group_id`, `cancelled_room_ids` in original room
  order, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`. Full cancellation
  settles only the remaining active rooms.
- `reduce_cash_payment`: `payment_operation_id` and positive integer `amount_cents`. Removes only
  that payment's held cash, in reverse fill order. The result includes the payment identifier,
  derived `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
- `charge_back_payment`: `payment_operation_id`. Reclassifies all of the payment's cash except
  previous reductions, removing held funding and revoking credit entitlements from converted cash.
  The result includes the payment identifier, derived `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`. Active and cancelled payment groups are eligible.

All three use the common `operation_id` and `occurred_on` fields, optional `expected_revision`, and
existing durable retry semantics. Payment corrections derive their group from the original applied
cash payment; `group_id` is not required. They increment only that group's revision. Original
payment results remain immutable.

Invalid selections return `invalid_rooms`. Missing payment records return `operation_not_found`;
ineligible records return `payment_not_reducible` or `payment_not_chargeable`. Reductions additionally
use `invalid_amount` and `reduction_exceeds_held_cash`. A fully reduced or already charged-back
payment cannot be charged back. Existing group revision checks precede these domain rules once an
applied payment identifies the group.

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` with exactly:

- `payment_operation_id`, `original_group_id`;
- `recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`,
  `converted_to_credit_cents`, `reduced_cents`, `charged_back_cents`.

All monetary fields are present. The six dispositions sum to recorded cash. Missing records return
404 with `operation_not_found`; records other than applied cash payments return 422 with
`payment_not_reconcilable`. Unattributed legacy funding has no readable or correctable payment id.

The ledger also includes `cash_converted_to_credit_cents`, `cash_reduced_cents`,
`cash_charged_back_cents`, `credit_liability_cents`, and `credit_shortfall_cents`. Refunds, retentions,
and conversions are current cash classifications and can decrease upon chargeback; reductions and
chargebacks are cumulative. Credit shortfall measures unrecovered clawback still covered by credit
applied to active groups. Those applied amounts continue to count toward liability. Restored credit
absorbs unrecovered clawback before excess is made available or expires. See
[the room accounting request](requests/04-room-accounting-and-payment-reductions.md) for the
entitlement rounding and settlement rules.
