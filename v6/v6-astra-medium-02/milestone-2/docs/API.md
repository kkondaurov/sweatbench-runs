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
- `deposit_paid_cents` (cash plus credit currently applied)
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Groups also include a fixed `policy_version`: `flex-14` for flexible bookings before
`2027-01-01`, `flex-30` for later flexible bookings, or `advance-nonrefundable`.
`refundable_until` is the inclusive cancellation deadline (arrival minus 14 or 30 days),
or `null` for advance purchase. Rescheduling preserves the policy and returns both fields
with the updated deadline.

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
    "cash_retained_cents": 0,
    "cash_converted_to_credit_cents": 0,
    "credit_liability_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted to hotel credit. Unpaid deposit requirements are not cash and never appear in these
totals.

`cash_converted_to_credit_cents` is cumulative original cash exchanged for hotel credit,
excluding the bonus. `credit_liability_cents` includes unexpired available credit and credit
applied to active groups. Redemption pauses expiry; non-refundable consumption reduces liability.

## Cancellation and hotel credit

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`.
A refundable hotel-credit cancellation converts its cash funding into a lot with a 10% bonus,
rounded to the nearest cent with halves upward. Results include `credit_issued_cents`,
`refunded_cents`, `retained_cents`, and `revision`. Converted cash is neither refunded nor retained.
Requesting hotel credit for a non-refundable cancellation returns `refund_method_not_available`.
An unrecognized refund method returns `invalid_operation`.

Previously applied credit is restored to its original lots on refundable cancellation, with no
new bonus. Restored amounts whose original expiry has passed expire immediately. Non-refundable
cancellation consumes applied credit and retains only the cash funding.

`apply_hotel_credit` supplies `group_id`, a positive integer `amount_cents`, and the common
operation fields. It accepts `expected_revision` and returns `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. The group must be active and the amount must fit its
outstanding deposit. Existing payment validation errors apply; insufficient unexpired guest credit
returns `insufficient_credit`. Lots are consumed by expiry, then `source_operation_id`.

## Read guest credit

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

Lots remain available through cancellation plus 365 days. Expired and exhausted lots are omitted;
remaining lots are ordered by `expires_on`, then `source_operation_id`. Guests without available
credit return zero and an empty array.

Both this endpoint and `/ledger` accept `on=YYYY-MM-DD` to evaluate expiry, defaulting to the
current UTC date. This filters current balances by expiry; it does not replay historical
operations or mutate balances. Invalid dates return `422` with `{"error":{"code":"invalid_date"}}`.
Credit application evaluates expiry on the operation's `occurred_on` date.
