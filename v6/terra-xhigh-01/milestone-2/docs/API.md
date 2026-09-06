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

### Cancellation policy and hotel credit

Flexible groups booked before `2027-01-01` use policy version `flex-14`; ones booked on or after
that date use `flex-30`. These policies allow cash settlement through 14 and 30 calendar days,
respectively, before arrival. Advance-purchase groups use `advance-nonrefundable`.

`cancel_group` accepts an optional `refund_method` of `cash` (the default) or `hotel_credit`.
For a refundable cash-funded cancellation, `hotel_credit` creates credit worth the cash amount plus
a 10% bonus rounded to the nearest cent, with exact half-cents rounded upward. It is rejected as
`refund_method_not_available` for a non-refundable cancellation. Applied cancellation results add
`credit_issued_cents` alongside `refunded_cents`, `retained_cents`, and `revision`.

`apply_hotel_credit` supplies `group_id` and a positive `amount_cents`. It applies the guest's
unexpired credit to an active group's outstanding deposit and returns the group ID, amount,
outstanding deposit, and revision. It is rejected with `insufficient_credit` when the guest lacks
enough available credit; invalid and oversized amounts use the existing payment error codes.

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

Groups also include the fixed `policy_version` and `refundable_until`. The latter is the final
refundable date for flexible groups and is `null` for advance-purchase groups.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Read finance totals

`GET /api/v1/ledger?on=YYYY-MM-DD`

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
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals. `cash_converted_to_credit_cents` is the cumulative cash amount converted into hotel credit.
`credit_liability_cents` includes both available credit and credit paused while applied to active
groups. The optional `on` query evaluates credit expiry on that date; without it the current UTC
date is used.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit?on=YYYY-MM-DD`

Returns the guest's available, unexpired hotel-credit lots and their total. Lots are ordered by
expiry date, then by source operation identifier; exhausted and expired lots are omitted. The
optional `on` query evaluates expiry on that date and defaults to the current UTC date.

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
