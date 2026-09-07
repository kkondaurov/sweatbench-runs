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

## Cancellation policies and hotel credit

Groups also expose `policy_version`, `refundable_until`, `cash_paid_cents`, and
`credit_paid_cents`. The two paid amounts sum to `deposit_paid_cents`. Flexible bookings
before 2027-01-01 use `flex-14`; later bookings use `flex-30`. Advance purchase uses
`advance-nonrefundable` with a null deadline. The policy is fixed at booking; rescheduling
recomputes the deadline and returns it alongside the policy version.

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"` and
returns `credit_issued_cents` in addition to its existing settlement fields. Refundable
cash converted to credit receives a rounded 10% bonus and expires after its inclusive
365-day validity period. Previously applied credit returns to its original lots without
a bonus; amounts restored after their original expiry are lost. Non-refundable
cancellation consumes applied credit and retains cash. Requesting hotel credit for it
returns `refund_method_not_available`. An unknown refund method returns `invalid_operation`.

`apply_hotel_credit` accepts `group_id`, `amount_cents`, `occurred_on`, `operation_id`,
and optional `expected_revision`. It uses the same payment validation and result fields
as cash payments, with `insufficient_credit` when the guest's unexpired balance cannot
cover the amount. Lots are used by expiry, then source operation identifier.

`GET /api/v1/guests/:guest_id/credit` returns `data` containing `guest_id`,
`available_cents`, and `lots`. Each lot contains `source_operation_id`, `remaining_cents`,
and `expires_on`; expired and exhausted lots are omitted. Unknown guests have an empty
balance. Lots are ordered by expiry, then source operation identifier.

The ledger adds cumulative `cash_converted_to_credit_cents` and current
`credit_liability_cents`. Liability includes available credit and credit allocated to
active groups, whose expiry is paused. Both ledger and guest credit reads accept
`on=YYYY-MM-DD`, defaulting to today's UTC date. This controls expiry evaluation over
current balances, not historical replay. Invalid dates return HTTP 422 with
`{"error":{"code":"invalid_date"}}`. Applying credit uses the operation date.
