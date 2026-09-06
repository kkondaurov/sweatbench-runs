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

## Room accounting and cash corrections

Rooms now also contain `status`, `lodging_total_cents`, `deposit_due_cents`,
`cash_paid_cents`, and `credit_paid_cents`. Rooms retain their original order and lodging
amount after cancellation; cancelled rooms have zero due, cash paid, and credit paid.
Group lodging, due, paid, and outstanding totals include only active rooms. New cash and
credit fill active room deposits in original room order without moving existing funding.

The following operations use the same common `operation_id`, `type`, and `occurred_on`
fields and durable retry behavior as other operations:

- `cancel_rooms`: supplies `group_id`, a nonempty `room_ids` array of distinct active
  rooms, and optional `refund_method` (`cash` by default or `hotel_credit`). The result
  contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
  `retained_cents`, `credit_issued_cents`, and `revision`. Invalid selections reject with
  `invalid_rooms`. Policy, expiry, and credit restoration rules match `cancel_group`.
  A credit bonus is rounded once over the selected rooms' combined cash. Cancelling the
  last active room cancels the group; `cancel_group` settles only rooms still active.
- `reduce_cash_payment`: supplies `payment_operation_id` and positive integer
  `amount_cents`. It removes only that payment's held cash, in reverse fill order. The
  result contains `payment_operation_id`, `group_id`, `amount_cents`,
  `outstanding_deposit_cents`, and `revision`. Rejections use `operation_not_found`,
  `payment_not_reducible`, `invalid_amount`, or `reduction_exceeds_held_cash`.
- `charge_back_payment`: supplies `payment_operation_id` and reverses every disposition
  of that payment except previously reduced cash. The result contains
  `payment_operation_id`, `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`. Missing records return
  `operation_not_found`; ineligible records, fully reduced payments, and payments already
  charged back return `payment_not_chargeable`. Active and cancelled groups are eligible.

Each accepts optional `expected_revision`. Payment corrections derive the addressed group
from the original applied cash payment, and only that group's revision advances. The
original payment's durable result remains unchanged. Chargebacks can revoke credit created
by cash conversion without changing any recipient group's funding or revision.

A converted payment's credit entitlement includes its share of the rounded bonus. For a
lot funded by several payments, entitlement is the difference between successive running
cash totals with their 10% bonuses, in funding order. Revocation consumes remaining credit
first. Unrecovered entitlement creates a current shortfall capped by that lot's credit still
applied to active rooms. Returned credit absorbs unrecovered clawback before expiry is
checked or any excess becomes available.

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}`. A statement
contains exactly these fields:

```json
{
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
```

The six dispositions sum to `recorded_cents`. Missing durable records return `404` with
`operation_not_found`; records other than applied cash payments return `422` with
`payment_not_reconcilable`. Reads have no side effects.

The ledger additionally exposes cumulative `cash_reduced_cents` and
`cash_charged_back_cents`, and current `credit_shortfall_cents`. Recorded cash equals held,
refunded, retained, converted, reduced, and charged-back cash. A chargeback reclassifies
historical refunded, retained, or converted principal without moving money again.
`credit_liability_cents` includes applied credit covered by a shortfall. Unspent revocation,
absorbed restoration, expiry, and non-refundable credit consumption reduce liability.
