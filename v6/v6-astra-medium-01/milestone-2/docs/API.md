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
to refunded, retained, or converted-to-credit totals. Unpaid deposit requirements are not cash and never appear in these
totals.

## Cancellation policies and hotel credit

Group reads also contain `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and
`refundable_until`. `deposit_paid_cents` is the sum of cash and credit funding. Funding totals remain
on cancelled groups; their outstanding deposit is zero.

The policy is fixed at opening: flexible bookings before `2027-01-01` use `flex-14`, later bookings
use `flex-30`, and advance purchase uses `advance-nonrefundable`. The flexible cutoff is arrival
minus 14 or 30 calendar days, inclusive; advance purchase has a null cutoff. Reschedule results
include the fixed `policy_version` and recomputed `refundable_until`.

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`. Unsupported values
are rejected with `invalid_operation`. Hotel credit on a non-refundable cancellation is rejected
with `refund_method_not_available`. Successful cancellation results add `credit_issued_cents`.
Refundable cash converted to credit receives a 10% bonus, rounded half upward, and is available
through cancellation plus 365 days. Previously applied credit returns to its original lots without
a bonus; amounts restored after their expiry expire immediately. Non-refundable cancellation
retains cash and consumes applied credit.

`apply_hotel_credit` takes `group_id`, `amount_cents`, and the common operation fields, including
optional `expected_revision`. It uses the guest's available lots on `occurred_on`, ordered by expiry
then source operation identifier. It returns `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Payment validation errors apply; inadequate unexpired
credit returns `insufficient_credit`. All rejections preserve the group, lots, and ledger.

`GET /api/v1/guests/:guest_id/credit` returns:

```json
{
  "data": {
    "guest_id": "guest-22",
    "available_cents": 5500,
    "lots": [
      {
        "source_operation_id": "cancel-17",
        "remaining_cents": 5500,
        "expires_on": "2028-05-02"
      }
    ]
  }
}
```

Lots are ordered by `expires_on`, then `source_operation_id`; exhausted and expired lots are omitted.
A guest with no credit receives zero available cents and an empty array.

Ledger reads add `cash_converted_to_credit_cents` (cumulative original cash converted, excluding
bonuses) and `credit_liability_cents` (unexpired available credit plus all credit funding active
groups). Conversion removes cash from held cash without increasing refunded or retained cash.
Credit expiry is paused while funding an active group.

Both credit and ledger reads accept `?on=YYYY-MM-DD`, defaulting to the current UTC date. This date
controls expiry evaluation of current balances, rather than reconstructing historical operations.
Reads do not mutate balances. Invalid dates return `422` with `{"error":{"code":"invalid_date"}}`.
