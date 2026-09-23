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

Groups also include `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and
`refundable_until`. `policy_version` is `flex-14` for flexible groups booked before
`2027-01-01`, `flex-30` for flexible groups booked on or after that date, and
`advance-nonrefundable` for advance-purchase groups. The version is based on the original booking
date and stays fixed when a group is rescheduled. `refundable_until` is the arrival date minus the
policy window, inclusive for cancellation, and is `null` for advance purchase.

## Hotel credit operations

`cancel_group` accepts optional `refund_method: "cash" | "hotel_credit"`; omission means `cash`.
Requesting hotel credit is rejected with `refund_method_not_available` when the group's policy is
non-refundable. A refundable cancellation that selects hotel credit issues a lot worth the cash
paid plus a 10% bonus rounded to the nearest cent, with half cents rounded upward. It is available
through 365 days after cancellation and expires the next day. The result includes
`credit_issued_cents`. Cash converted into credit is recorded in `cash_converted_to_credit_cents`;
it is not counted as refunded or retained cash.

`apply_hotel_credit` contains `group_id` and `amount_cents`. It requires an active group, a positive
amount no greater than the outstanding deposit, and enough unexpired credit for the guest. It
returns `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`. Insufficient balance
is rejected with `insufficient_credit`. Lots are consumed by expiry date and then source operation
identifier. A refundable cancellation restores applied credit to its original lots; a
non-refundable cancellation consumes that credit.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit` returns the guest's available credit and unexpired lots,
ordered by `expires_on`, then `source_operation_id`:

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

Both this endpoint and `GET /api/v1/ledger` accept optional `on=YYYY-MM-DD`. It controls which
credit lots count as available on that date: a lot must have been issued by then and not yet
expired. Without it, the current UTC date is used. Credit application checks lot availability
against the operation's `occurred_on` date.

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
to refunded cash, retained cash, or converted credit. Unpaid deposit requirements are not cash and
never appear in these totals. `credit_liability_cents` includes unexpired available credit and
credit applied to active groups; applying or restoring credit does not change liability unless the
restored lot has expired. Expiry and non-refundable consumption reduce it.
