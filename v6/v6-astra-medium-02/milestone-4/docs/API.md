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
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Cancelled rooms remain in original
order with their original prices and no held funding. Group lodging, due, paid, and outstanding
totals include active rooms only. Cash and credit fill active room deposits in original room order;
later funding fills any outstanding gaps without moving existing allocations.

Group responses also include `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and
`refundable_until`. A missing group returns
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

## Room cancellations and payment corrections

All operations below include `operation_id`, `type`, and `occurred_on`, and accept
`expected_revision`. They use the same durable retry contract as other operations: an equivalent
submission replays its exact original applied or rejected result; a changed submission using the
same identifier is rejected with `operation_id_conflict`.

- `cancel_rooms`: supply `group_id`, a nonempty `room_ids` array of distinct active rooms, and
  optional `refund_method` (`cash` by default, or `hotel_credit`). Invalid selections reject the
  entire operation with `invalid_rooms`. Settlement uses the group's fixed cancellation policy.
  The result contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
  `retained_cents`, `credit_issued_cents`, and `revision`. Credit bonuses are calculated once on
  combined selected cash. Other rooms keep their allocations. Cancelling the last active room
  cancels the group; `cancel_group` settles only remaining active rooms.
- `reduce_cash_payment`: supply `payment_operation_id` and positive integer `amount_cents`.
  Remove only that payment's held cash, in reverse fill order. The result contains
  `payment_operation_id`, derived `group_id`, `amount_cents`, `outstanding_deposit_cents`, and
  `revision`. Errors are `operation_not_found`, `payment_not_reducible`, `invalid_amount`, or
  `reduction_exceeds_held_cash`. Legacy unattributed cash has no targetable payment identifier.
- `charge_back_payment`: supply `payment_operation_id`. Reverse all its cash except amounts
  already reduced, including held, refunded, retained, and converted principal. The result
  contains `payment_operation_id`, derived `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`. Errors are `operation_not_found` or
  `payment_not_chargeable`. Fully reduced and already charged-back payments cannot be charged
  again under another operation identifier. Both active and cancelled groups can be addressed.

Payment corrections check the original payment group's revision before evaluating current cash
availability or reduction amounts. They increment only that group's revision. Payment results and
historical cancellation results remain unchanged.

Chargebacks revoke the payment's share of issued credit, including its share of the rounded bonus.
Each lot assigns shares in funding order using differences between cumulative bonus-inclusive
amounts. Revocation removes unspent credit first. Unrecovered entitlement produces a shortfall up
to the amount of that lot still applied to active groups. Returned credit absorbs unrecovered
clawback before becoming available or expiring. Affected credit-funded groups retain their
allocations and revisions.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, return `{"data": <statement>}` with exactly:

- `payment_operation_id`, `original_group_id`;
- `recorded_cents`;
- `held_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`, `reduced_cents`,
  `charged_back_cents`.

All monetary fields are present. The six dispositions sum to `recorded_cents`. Reads do not change
state. Missing records return `404` with `operation_not_found`; other operation records return
`422` with `payment_not_reconcilable`.

The ledger additionally exposes `cash_converted_to_credit_cents`, `cash_reduced_cents`,
`cash_charged_back_cents`, `credit_liability_cents`, and `credit_shortfall_cents`. Recorded cash
is the sum of held, refunded, retained, converted, reduced, and charged-back cash. Chargebacks
reclassify past settlements without initiating a new refund or reversing the historical movement
of money. Credit liability includes available unexpired credit and all credit applied to active
rooms, including credit covered by a current shortfall.

The ledger and `GET /api/v1/guests/:guest_id/credit` accept `on=YYYY-MM-DD` to evaluate expiry;
the default is the current UTC date. Operation processing uses `occurred_on` for expiry.
