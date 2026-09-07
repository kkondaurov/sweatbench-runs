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

Group reads also include the fixed booking-time `policy_version` (`flex-14`,
`flex-30`, or `advance-nonrefundable`) and `refundable_until` (an inclusive
date, or null for advance purchase). Reschedule results include both fields with
the updated deadline. Flexible bookings from 2027-01-01 use 30 days; earlier
bookings retain 14 days.

`cancel_group` accepts `refund_method: "cash" | "hotel_credit"`, defaulting to
cash. Unsupported values return `invalid_operation`; hotel credit for a
non-refundable cancellation returns `refund_method_not_available`. Results
include `credit_issued_cents`. Refundable cash converted to credit earns a
rounded 10% bonus. Previously applied credit returns to its original lots without
a bonus, and expires immediately if its original expiry has passed.

`apply_hotel_credit` accepts `group_id`, positive integer `amount_cents`,
and optional `expected_revision`. Its applied result includes `group_id`,
`amount_cents`, `outstanding_deposit_cents`, and `revision`. It uses payment
validation errors, plus `insufficient_credit`. Credit is guest-specific and
redeemed by expiry, then source operation identifier.

Group reads include `cash_paid_cents` and `credit_paid_cents`;
`deposit_paid_cents` is their sum. Funding totals remain historical after cancellation.

`GET /api/v1/guests/:guest_id/credit` returns `data` containing `guest_id`,
`available_cents`, and `lots`. Each lot contains `source_operation_id`,
`remaining_cents`, and `expires_on`. Only unexpired, nonempty lots appear,
ordered by expiry and source identifier. Unknown guests have an empty balance.

Credit and ledger reads accept `on=YYYY-MM-DD`, defaulting to the current UTC
date. Invalid dates return 422 with `{"error":{"code":"invalid_date"}}`.
These are current balances evaluated for expiry on that date, not historical
snapshots. Credit remains available on its expiry date.

The ledger adds `cash_converted_to_credit_cents` (cumulative original cash,
excluding bonuses) and `credit_liability_cents` (unexpired available credit plus
credit funding active groups). Applied credit's expiry is paused until settlement.
