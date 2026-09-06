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
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Funding fills active rooms in
original room order. Cancelled rooms remain in the response with zero lodging, due, and paid amounts.
Group lodging, due, paid, and outstanding totals include active rooms only. Group responses also
include `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and `refundable_until`.
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
to refunded, retained, or converted-to-credit cash. Unpaid deposit requirements are not cash and
never appear in these totals.

The ledger also includes `cash_converted_to_credit_cents`, cumulative `cash_reduced_cents` and
`cash_charged_back_cents`, plus current `credit_liability_cents` and `credit_shortfall_cents`.
Recorded cash is the sum of held, refunded, retained, converted, reduced, and charged-back cash.
Credit liability includes unexpired available credit and credit applied to active groups, including
any shortfall. Ledger and guest-credit reads accept `on=YYYY-MM-DD`, defaulting to today in UTC.

## Cancel selected rooms

`cancel_rooms` supplies `group_id`, a nonempty `room_ids` array of distinct active room identifiers,
and optional `refund_method` (`cash`, the default, or `hotel_credit`), along with the common
`operation_id`, `type`, and `occurred_on` fields. It accepts `expected_revision`.

Invalid room selections return `invalid_rooms` without settling any room. The applied result
contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. Settlement uses the group's fixed cancellation policy.
A hotel-credit bonus is rounded once on the selected rooms' combined cash. Existing credit returns
to its original lots on refundable cancellation. Other rooms keep their allocations.
Cancelling the final active room cancels the group; `cancel_group` settles remaining active rooms.

## Correct a cash payment

`reduce_cash_payment` supplies `payment_operation_id` and a positive integer `amount_cents`.
`charge_back_payment` supplies `payment_operation_id` and reverses all unreduced cash from that
payment. Both require the common operation fields and accept `expected_revision`, checked against
the original payment's group before domain validation. They derive `group_id` from the payment.

A reduction removes only that payment's held cash, in reverse room fill order, reopening the
outstanding deposit. A chargeback also reclassifies refunded, retained, and converted principal;
it does not issue or undo a guest refund. A chargeback can address a cancelled group.

Applied reductions return `payment_operation_id`, `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Chargebacks return the same fields with
`charged_back_cents` replacing `amount_cents`. Only the original group's revision increments.

Missing payment records return `operation_not_found`. A record that cannot accept a reduction
returns `payment_not_reducible`; unusable amounts return `invalid_amount`, and amounts above a
positive remaining held balance return `reduction_exceeds_held_cash`. Chargebacks return
`payment_not_chargeable` for non-payments, rejected payments, fully reduced payments, or payments
already charged back. Legacy unattributed funding cannot be targeted.

Converted cash creates credit entitlement per payment using cumulative half-up bonus rounding
in funding order, independently for each issued lot. Chargeback revokes that entitlement from the
lot's remaining balance first. Any unrecovered entitlement absorbs subsequent refundable credit
restorations before expiry is evaluated. The current shortfall for a lot is the lesser of its
unrecovered clawback and credit still applied to active groups. Credit-funded groups keep their
state and revision when the original cash payment is charged back.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}`. A statement contains
exactly `payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`.
All amounts are always present. The six dispositions sum to `recorded_cents`.

A missing durable record returns `404` with `operation_not_found`; a record that is not an applied
cash payment returns `422` with `payment_not_reconcilable`. Reads never mutate accounting.

All new operations retain the durable retry contract: equivalent payloads return their exact
original result, changed payloads return `operation_id_conflict`, and handled rejections are
remembered. Corrections never rewrite the original payment result.
