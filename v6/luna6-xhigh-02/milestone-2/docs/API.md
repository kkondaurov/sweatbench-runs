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

In addition to `open_group`, `record_cash_payment`, `reschedule_group`, and `cancel_group`, batches
accept `apply_hotel_credit` with `group_id` and `amount_cents`. A cancellation may include
`refund_method: "cash"` or `refund_method: "hotel_credit"`; omitting it means `cash`.

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

Responses also include `cash_paid_cents`, `credit_paid_cents`, `policy_version`, and
`refundable_until`. Flexible groups booked before `2027-01-01` use `flex-14`; those booked on or
after that date use `flex-30`. Advance-purchase groups use `advance-nonrefundable`. The policy is
fixed at booking even when the group is rescheduled. `refundable_until` is the arrival date minus
the policy window, inclusive, and is `null` for advance purchase.

`apply_hotel_credit` consumes the guest's available credit in expiry and source-operation order,
adds it to the active group's deposit, and returns `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. It rejects an unusable amount with `invalid_amount`, an
amount above the outstanding deposit with `payment_exceeds_outstanding`, and a guest balance that
cannot cover the amount with `insufficient_credit`. The group read shows cash and credit
contributions separately in addition to their combined `deposit_paid_cents`.

An applied cancellation returns `group_id`, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. Refundable cancellations may convert cash to hotel credit.
The credit lot is worth the cash amount plus a 10% bonus rounded to the nearest cent, with half
cents rounded up. It remains available through the date 365 days after cancellation and expires the
following day. A refundable cancellation restores previously applied credit to its original lots
and expiries. A non-refundable cancellation consumes applied credit. Requesting hotel credit for a
non-refundable cancellation is rejected with `refund_method_not_available`.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

Returns the guest's unexpired, unspent lots ordered by `expires_on`, then by `source_operation_id`:

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

Both this endpoint and `/api/v1/ledger` accept an optional `on=YYYY-MM-DD` query parameter to
evaluate credit expiry as of that date. Without it, they use the current UTC date. Applied credit
remains part of the liability while it funds an active group, even after its lot's expiry date.

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
to refunded, retained, or converted to hotel credit. `credit_liability_cents` includes available
credit and credit applied to active groups. Expired available credit and credit consumed by a
non-refundable cancellation are excluded. Unpaid deposit requirements are not cash and never
appear in these totals.
