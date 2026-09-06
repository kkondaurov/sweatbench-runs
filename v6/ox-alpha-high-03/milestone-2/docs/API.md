# Partner API

All endpoints are below `/api/v1` and exchange JSON. Authentication is handled upstream and is not
part of this application.

Dates use ISO 8601 calendar dates. Monetary amounts are integer cents. Identifiers are
partner-supplied strings and must be returned unchanged.

## Operations

Operations are identified by their `type`. The service supports `open_group`,
`record_cash_payment`, `reschedule_group`, `cancel_group`, and
`apply_hotel_credit`.

## Cancellation policies

A group's policy version is fixed when the group is opened and never changes,
including across reschedules:

- flexible groups booked before `2027-01-01` use `flex-14` (14-day window);
- flexible groups booked on or after `2027-01-01` use `flex-30` (30-day window);
- advance-purchase groups use `advance-nonrefundable`.

Group responses include `policy_version` and `refundable_until`, the arrival
date minus the cancellation window. A flexible cancellation on that date is
still refundable. `refundable_until` is `null` for advance purchase.

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

## Cancel with cash or hotel credit

A `cancel_group` operation accepts an optional `refund_method`, either `cash`
or `hotel_credit`. Omitting it means cash. Requesting `hotel_credit` for a
non-refundable cancellation is rejected as `refund_method_not_available` and
leaves the group active; an unknown `refund_method` is rejected as
`invalid_operation`.

When a refundable cancellation converts cash to credit, the result contains
`refunded_cents: 0`, `retained_cents: 0`, and `credit_issued_cents`: a new
credit lot worth 110% of the paid cash, available through 365 days after the
cancellation and expiring the following day. The lot's
`source_operation_id` is the cancellation operation's identifier. All
cancellation results include `credit_issued_cents`.

## Apply hotel credit

An `apply_hotel_credit` operation contains `group_id` and `amount_cents`. It
redeems the guest's unexpired credit into an active group's outstanding
deposit, consuming lots by earliest expiry and then by `source_operation_id`.
Credit applied to a group keeps its value while that group is active regardless
of lot expiry; it returns to its original lots on a refundable cancellation
(unless already expired on the cancellation date, in which case it expires
immediately) and is consumed by a non-refundable one.

The applied result contains `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. A guest who cannot cover the
requested amount is rejected with `insufficient_credit`; existing payment
validation errors apply otherwise.

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then
by `source_operation_id`. The endpoint accepts an optional `on=YYYY-MM-DD`
query parameter and reports expiry as of that date; without it, the current UTC
date is used.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id` and `nightly_rate_cents`. A group also reports
`policy_version`, `refundable_until`, `cash_paid_cents`, and
`credit_paid_cents`. A missing group returns
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
to refunded, retained, or converted to credit. Unpaid deposit requirements are not cash and never appear in these
totals.

`credit_liability_cents` includes both available credit and credit currently
applied to active groups, reporting expiry as of the optional `on=YYYY-MM-DD`
query parameter (the current UTC date when omitted).
