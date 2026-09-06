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
- `cash_paid_cents`
- `credit_paid_cents`

`deposit_paid_cents` is the sum of cash and hotel credit currently funding the deposit. Cancellation
clears all three paid balances and the deposit requirement.

Groups also include their fixed `policy_version`: `flex-14` for flexible bookings before
`2027-01-01`, `flex-30` for later flexible bookings, or `advance-nonrefundable`. Their
`refundable_until` is the arrival date minus 14 or 30 days, inclusive, or `null` for advance
purchase. Rescheduling preserves the policy and returns the recomputed `refundable_until` and
`policy_version` alongside the new stay dates and revision.

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
to refunded, retained, or converted to credit. Unpaid deposit requirements are not cash and never
appear in these totals. `cash_converted_to_credit_cents` is cumulative original cash, excluding
credit bonuses. `credit_liability_cents` includes available unexpired credit and all credit funding
active groups, whose expiry is paused. Expiry and non-refundable consumption reduce liability.

## Cancellation refund methods

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`. Invalid values
are rejected with `invalid_operation`. Requesting hotel credit for a non-refundable cancellation
returns `refund_method_not_available` and leaves the group active.

A refundable cancellation with hotel credit converts paid cash into a credit lot with a 10% bonus,
rounded to the nearest cent with half-cents rounded upward. The lot's `source_operation_id` is the
cancellation identifier. It remains available through cancellation date plus 365 days. Both
`refunded_cents` and `retained_cents` are zero for this conversion. Cancellation results always
include `credit_issued_cents` in addition to the cash settlement fields and resulting `revision`.

On refundable cancellation, previously applied credit returns to its original lots and expiry,
without another bonus, regardless of refund method. Restored amounts whose original expiry is past
expire immediately. On non-refundable cash cancellation, cash is retained and applied credit is
consumed.

## Apply hotel credit

`apply_hotel_credit` supplies the common operation fields, `group_id`, and positive integer
`amount_cents`. It applies the group's guest's unexpired credit, consuming lots by earliest expiry
then `source_operation_id`. It uses the operation's `occurred_on` to evaluate expiry.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
It uses the existing payment validation errors and `insufficient_credit` when the guest cannot
cover the requested amount. Revision checks precede domain validation, as for cash payments.

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then
`source_operation_id`. A guest without available credit returns zero and an empty lot array.

Both this endpoint and `/api/v1/ledger` accept optional `on=YYYY-MM-DD`, defaulting to the current
UTC date. This date evaluates expiry against current balances; it does not reconstruct historical
transactions. Reads do not change balances. Invalid dates return `422` with
`{"error":{"code":"invalid_date"}}`.
