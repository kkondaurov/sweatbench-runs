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
- `deposit_paid_cents` (cash plus hotel credit)
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Groups also include `policy_version` and `refundable_until`. Flexible groups booked before
`2027-01-01` use `flex-14`; later bookings use `flex-30`. The refundable deadline is arrival minus
14 or 30 days, inclusive. Advance-purchase groups use `advance-nonrefundable` with a `null` deadline.
The policy stays fixed when rescheduling; the deadline moves with arrival. Reschedule results include
both fields alongside the new arrival, departure, and revision.

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

`cash_converted_to_credit_cents` cumulatively records the original cash converted, excluding bonuses.
`credit_liability_cents` includes unexpired available credit and credit applied to active groups.
Redeemed credit keeps its liability even after its original expiry; non-refundable consumption and
expiry reduce the liability.

## Cancellation settlement

`cancel_group` accepts optional `refund_method: "cash"` (the default) or `"hotel_credit"`.
For refundable cancellations, cash is refunded or converted to a new credit lot with a 10% bonus,
rounded to the nearest cent with half-cent ties upward. The lot's `source_operation_id` is the
cancellation identifier and its inclusive expiry is cancellation plus 365 calendar days.
Applied credit returns to its original lots without another bonus; amounts whose original expiry
has passed expire immediately when restored.

For non-refundable cancellations, cash is retained and applied credit is consumed. Requesting
hotel credit for such a cancellation rejects with `refund_method_not_available`. Other refund
method values reject with `invalid_operation`. Rejections leave all accounting and revisions unchanged.

Results contain `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`.
Converting cash to credit sets both refunded and retained amounts to zero.

## Apply hotel credit

`apply_hotel_credit` takes `group_id`, `amount_cents`, `occurred_on`, and optional
`expected_revision`, in addition to `operation_id` and `type`. It funds the group's outstanding
deposit using the guest's credit, across properties. Lots are consumed by earliest expiry, then
`source_operation_id`. Expiry is evaluated on the operation date and pauses while credit funds an
active group.

The existing payment errors apply: `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding`. Insufficient unexpired guest credit returns `insufficient_credit`.
Group existence and revision are checked before domain validation. Applied results contain
`group_id`, `amount_cents`, `outstanding_deposit_cents`, and the incremented `revision`.

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

Expired and exhausted lots are omitted. Lots are ordered by expiry, then source operation identifier.
Guests with no available credit receive zero and an empty list.

The guest-credit and ledger endpoints accept optional `on=YYYY-MM-DD`, defaulting to the current
UTC date. This date controls expiry filtering of current balances; it does not replay historical
operations. Reads do not mutate credit. An invalid date returns `422` with
`{"error":{"code":"invalid_date"}}`.
