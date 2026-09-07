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
- `deposit_paid_cents` (cash plus hotel credit currently applied)
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Groups also include their fixed `policy_version`: `flex-14` for flexible bookings before
`2027-01-01`, `flex-30` for flexible bookings on or after that date, and
`advance-nonrefundable` for advance purchase. `refundable_until` is the inclusive cancellation
deadline (arrival minus 14 or 30 days), or `null` for advance purchase. Rescheduling preserves the
policy and returns both `policy_version` and the recomputed `refundable_until`.

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
to refunded, retained, or converted to hotel credit. Unpaid deposit requirements are not cash and
never appear in these totals.

`cash_converted_to_credit_cents` cumulatively records the original cash exchanged for hotel
credit. `credit_liability_cents` includes unexpired available credit plus all credit currently
funding active groups. Applying credit does not change liability; expiry and non-refundable
consumption reduce it. Cash totals never include hotel credit or its bonus.

## Cancel with hotel credit

`cancel_group` accepts optional `refund_method: "cash" | "hotel_credit"`, defaulting to `cash`.
Unsupported values are rejected with `invalid_operation`. Requesting hotel credit for a
non-refundable cancellation returns `refund_method_not_available` and leaves the group active.

For a refundable cancellation, selecting hotel credit converts the cash-funded deposit to a new
lot with a 10% bonus, rounded to the nearest cent with half-cents upward. The lot's
`source_operation_id` is the cancellation identifier. It is available through cancellation plus
365 days. Cash refunded and retained are both zero for this conversion. Cancellation results
include `credit_issued_cents` alongside `refunded_cents`, `retained_cents`, and `revision`.

Previously applied credit is restored to its original lots and expiry on refundable cancellation,
regardless of refund method, and receives no additional bonus. Restored amounts whose original
expiry is past on the cancellation date expire immediately. Non-refundable cancellations retain
cash and consume applied credit. Cancellation clears all current deposit balances.

## Apply hotel credit

`apply_hotel_credit` supplies `group_id`, `amount_cents`, and the common operation fields. It also
accepts `expected_revision`. It applies the guest's credit to the active group's outstanding
deposit, consuming lots by earliest `expires_on`, then `source_operation_id`.

It uses the existing payment validation errors and returns `insufficient_credit` when the guest
has too little unexpired credit on the operation's `occurred_on` date. Existence and revision checks
precede domain validation. Rejections leave both the group and credit balances unchanged.
Applied results contain `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

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

Only unexpired lots with positive remaining balances are included, ordered by `expires_on`, then
`source_operation_id`. Guests without credit receive zero available cents and an empty list.

Both this endpoint and `/ledger` accept optional `on=YYYY-MM-DD` to evaluate expiry, defaulting to
the current UTC date. Invalid dates return `422` as `{"error":{"code":"invalid_date"}}`. These
reads evaluate the current accounting state using the requested expiry date; they do not replay
historical operations or change stored balances. Applied credit is excluded from available lots
and remains in the liability even after its original expiry.
