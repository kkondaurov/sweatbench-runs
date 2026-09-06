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

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking
and stay dates, rate plan, fixed `policy_version`, `refundable_until`, status, rooms in their
original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

Flexible groups booked before `2027-01-01` use policy version `flex-14`; later flexible groups use
`flex-30`. Their refundable deadline is respectively 14 or 30 days before arrival, inclusive.
Advance-purchase groups use `advance-nonrefundable` and have a null refundable deadline.

## Hotel credit operations

`cancel_group` accepts an optional `refund_method` of `cash` or `hotel_credit`; omission means
cash. A refundable cash-funded deposit converted to hotel credit receives a rounded 10% bonus and
is available through 365 days after cancellation. The result includes `credit_issued_cents` in
addition to `refunded_cents`, `retained_cents`, and `revision`. Hotel credit is rejected for a
non-refundable cancellation with `refund_method_not_available`.

`apply_hotel_credit` contains `group_id` and `amount_cents`. It applies the guest's unexpired credit
to an active group's outstanding deposit, consuming lots by earliest expiry and then
`source_operation_id`. The applied result contains `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Rejections use `invalid_amount`,
`payment_exceeds_outstanding`, or `insufficient_credit` as appropriate and follow the standard
revision contract.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

The response contains the guest identifier, total available cents, and unexpired, non-empty lots:

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

Lots are ordered by `expires_on` and then `source_operation_id`. An unknown guest has a zero
balance and no lots. The optional `on=YYYY-MM-DD` query parameter evaluates expiry on that date;
without it the endpoint uses the current UTC date.

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
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

`cash_converted_to_credit_cents` is the cumulative cash principal converted during refundable
cancellations. `credit_liability_cents` includes unexpired available credit and credit applied to
active groups. The ledger also accepts `on=YYYY-MM-DD` for expiry evaluation and otherwise uses the
current UTC date.
