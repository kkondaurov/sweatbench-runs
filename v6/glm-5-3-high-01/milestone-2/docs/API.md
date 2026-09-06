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

## Cancellation policies

A group's policy version is fixed when it is opened:

- flexible groups booked before `2027-01-01` use `flex-14`, a fourteen-day cancellation window;
- flexible groups booked on or after `2027-01-01` use `flex-30`, a thirty-day cancellation window;
- advance-purchase groups use `advance-nonrefundable`.

Rescheduling a group never changes its policy version.

A flexible cancellation is refundable when it occurs on or before the group's `refundable_until`,
which is the arrival date minus its cancellation window. It is `null` for advance purchase.

## Hotel credit

A refundable cancellation may take a `refund_method` of `cash` (the default) or `hotel_credit`.
With `hotel_credit`, the cash-funded portion is converted into a credit lot worth 110% of that
cash, available through the date 365 days after the cancellation and expiring the following day.
The converted cash moves from `cash_held_cents` to `cash_converted_to_credit_cents`; nothing is
refunded or retained for that settlement. Requesting `hotel_credit` for a non-refundable
cancellation is rejected with `refund_method_not_available` and leaves the group active.

An `apply_hotel_credit` operation contains `group_id` and `amount_cents`. It redeems the guest's
unexpired credit into an active group's outstanding deposit, consuming lots by earliest expiry and
then by `source_operation_id`. Rejections use `insufficient_credit` when the guest cannot cover the
amount and the existing payment validation errors where they apply. Its applied result contains
`group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.

Applied hotel credit is restored to its original lot and expiry when the group is cancelled while
refundable, without a second bonus; a restored lot whose expiry has already passed does not become
available again. A non-refundable cancellation consumes applied hotel credit.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, `policy_version`, `refundable_until`, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Read a guest's credit

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then by
`source_operation_id`. An optional `on=YYYY-MM-DD` query parameter reports expiry as of that date;
without it the current UTC date is used. An unparseable `on` value returns
`422` as `{"error":{"code":"invalid_date"}}`.

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
to refunded, retained, or converted to hotel credit. `credit_liability_cents` is unexpired hotel
credit, both available and currently applied to active groups; expiry and non-refundable
consumption reduce it. Unpaid deposit requirements are not cash and never appear in these totals.

The ledger accepts an optional `on=YYYY-MM-DD` query parameter and reports credit expiry as of
that date; without it the current UTC date is used. An unparseable `on` value returns
`422` as `{"error":{"code":"invalid_date"}}`.
