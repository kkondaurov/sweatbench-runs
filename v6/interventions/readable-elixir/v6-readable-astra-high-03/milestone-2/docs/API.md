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

`deposit_paid_cents` is cash plus hotel credit currently applied to the deposit. Cancellation
clears all three paid totals and the outstanding obligation.

Groups also include `policy_version` and `refundable_until`. Flexible bookings before `2027-01-01`
use `flex-14`; bookings on or after that date use `flex-30`. Their inclusive refund deadline is
arrival minus 14 or 30 days respectively. Advance-purchase groups use `advance-nonrefundable` and
have a `null` deadline. The policy is fixed at opening, including for groups migrated from an
earlier release. Rescheduling recomputes the deadline and returns both fields alongside the new
arrival, departure, and revision.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancel a group

`cancel_group` accepts optional `refund_method: "cash" | "hotel_credit"`, defaulting to cash.
An unknown or null method is rejected as `invalid_operation`. Hotel credit is available only for
refundable cancellations; otherwise the operation is rejected as `refund_method_not_available`.

A refundable cash settlement refunds only cash funding. A refundable hotel-credit settlement
converts cash funding to a new guest credit lot, adding a 10% bonus rounded to the nearest cent
with half-cents rounded upward. The lot identifies the cancellation's `operation_id` as its
`source_operation_id` and is usable through cancellation plus 365 days. Zero cash creates no lot.
In either case, previously applied credit returns to its original lots without a bonus. Credit
restored after its original expiry is extinguished immediately.

A non-refundable cash settlement retains the cash and consumes applied credit. The applied result
contains `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`.
Credit conversion reports zero refunded and retained cents.

## Apply hotel credit

`apply_hotel_credit` contains `group_id` and a positive integer `amount_cents`. It follows the cash
payment validation and revision rules, including `payment_exceeds_outstanding`. If the guest's
unexpired credit cannot cover the amount, it returns `insufficient_credit`. Expiry is evaluated
using `occurred_on`. Lots are consumed by expiry, then `source_operation_id`.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
Credit is part of the active deposit, and its expiry is paused until cancellation settles it.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

Returns `{"data":{"guest_id":"guest-22","available_cents":5500,"lots":[...]}}`. Each lot has
`source_operation_id`, `remaining_cents`, and `expires_on`. Exhausted and expired lots are omitted;
available lots are ordered by expiry then source operation identifier. A guest without credit
receives zero available cents and an empty lots array.

This endpoint and the ledger accept optional `on=YYYY-MM-DD`, defaulting to the current UTC date.
The date evaluates expiry against current stored balances; it does not reconstruct historical
transactions. An invalid date returns `422` as `{"error":{"code":"invalid_date"}}`.

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
    "credit_liability_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted to credit. Converted cash is cumulative and excludes the bonus.
`credit_liability_cents` includes unexpired available credit and all credit applied to active
groups. Applying or restoring unexpired credit does not change liability; expiry and
non-refundable consumption reduce it. Unpaid deposit requirements are not cash and never appear in these
totals.
