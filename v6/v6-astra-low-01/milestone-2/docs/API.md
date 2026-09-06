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

## Cancellation policy and hotel credit

Groups also return `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and
`refundable_until`. The two funding totals sum to `deposit_paid_cents`.
Flexible bookings before 2027-01-01 use `flex-14`; later bookings use `flex-30`.
Their inclusive refund deadline is arrival minus 14 or 30 days, respectively.
Advance purchase uses `advance-nonrefundable` with a null deadline. Rescheduling
preserves the policy and returns it with the recomputed deadline.

`cancel_group` accepts `refund_method: "cash"` (the default) or
`refund_method: "hotel_credit"`. Refundable cash converted to credit receives a
10% bonus, rounded to the nearest cent with halves upward. The result includes
`credit_issued_cents` alongside cash `refunded_cents`, `retained_cents`, and
`revision`. Non-refundable hotel-credit requests reject with
`refund_method_not_available`; unknown refund methods reject with
`invalid_operation`.

`apply_hotel_credit` accepts `group_id`, positive integer `amount_cents`, and
optional `expected_revision`, along with the common operation fields. It returns
`group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
Payment validation errors apply; insufficient unexpired guest credit rejects with
`insufficient_credit`. Lots are consumed by expiry then source operation identifier.
Refundable cancellation restores redeemed credit to its original lots without a
second bonus; restored credit past its original expiry expires immediately.
Non-refundable cancellation consumes redeemed credit.

`GET /api/v1/guests/:guest_id/credit` returns `data` with `guest_id`,
`available_cents`, and `lots`. Each lot contains `source_operation_id`,
`remaining_cents`, and `expires_on`. Only unexpired, nonempty lots appear, ordered
by expiry then source operation identifier. Credit is available through 365 days
after its issuing cancellation. An unknown guest returns zero credit and an empty list.

The ledger adds cumulative `cash_converted_to_credit_cents` and current
`credit_liability_cents`. Liability includes available credit and credit funding
active groups, where expiry is paused. Conversion is neither a cash refund nor a
retained cancellation fee.

Both credit and ledger reads accept `on=YYYY-MM-DD` for expiry evaluation,
defaulting to the current UTC date. This selects the expiry date for current
balances, not a historical replay of operations. Invalid dates return
`422 {"error":{"code":"invalid_date"}}`. Credit application evaluates expiry on
the operation's `occurred_on` date.
