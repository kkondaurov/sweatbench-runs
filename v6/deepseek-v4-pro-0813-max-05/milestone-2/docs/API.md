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

## Cancellation policy and hotel credit

A group's cancellation policy is fixed when it is opened. Flexible groups booked before
`2027-01-01` use a 14-day cancellation window (`flex-14`); flexible groups booked on or after
that date use 30 days (`flex-30`). Advance-purchase groups are `advance-nonrefundable` and can
never be refunded. Rescheduling moves dates but never changes a group's policy.

`cancel_group` accepts an optional `refund_method`, either `cash` (the default) or
`hotel_credit`. A refundable cancellation with `hotel_credit` converts paid cash into a credit
lot worth 110% of that cash for the same guest. Hotel credit never makes a non-refundable
cancellation refundable: such an attempt is rejected with `refund_method_not_available` and the
group stays active.

Cash converted to credit is not refunded or retained; it moves from `cash_held_cents` to
`cash_converted_to_credit_cents`. The cancellation result includes `credit_issued_cents`, the
value of any lot issued by that operation.

Hotel credit is applied with an `apply_hotel_credit` operation:

```json
{
  "operation_id": "op-2100",
  "type": "apply_hotel_credit",
  "occurred_on": "2026-11-27",
  "group_id": "group-82",
  "amount_cents": 5500
}
```

The group must be active, the amount must not exceed the group's outstanding deposit
(`payment_exceeds_outstanding`), and the guest must have enough unexpired credit
(`insufficient_credit`). Lots are consumed by earliest expiry, then by `source_operation_id`.
Expiry is evaluated using the operation's `occurred_on`. The applied result contains `group_id`,
`amount_cents`, `outstanding_deposit_cents`, and `revision`.

Credit applied to a group is restored to its original lots on refundable cancellation; on
non-refundable cancellation it is consumed.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, `policy_version`, `refundable_until`, rooms in their original order, and these
totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

`refundable_until` is the last refundable cancellation date for flexible groups (arrival minus the
group's cancellation window) and `null` for advance purchase. Each room contains `room_id` and
`nightly_rate_cents`. A missing group returns `404` as `{"error":{"code":"group_not_found"}}`.

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
`source_operation_id`. An optional `on=YYYY-MM-DD` query parameter evaluates expiry as of that
date; without it the current UTC date is used. An unusable `on` value returns `422` as
`{"error":{"code":"invalid_date"}}`.

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
to either refunded or retained. `cash_converted_to_credit_cents` is the cumulative cash that
became hotel credit instead of a refund. `credit_liability_cents` is the total of available
credit plus credit currently applied to active groups. Unpaid deposit requirements are not cash
and never appear in these totals. The ledger accepts an optional `on=YYYY-MM-DD` query parameter
to evaluate credit expiry as of that date; an unusable value returns `422` as
`{"error":{"code":"invalid_date"}}`.
