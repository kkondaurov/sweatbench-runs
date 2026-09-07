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
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

`deposit_paid_cents` is the sum of cash and credit currently applied. Cancellation clears all
three paid balances and the deposit due. `policy_version` is fixed at booking: `flex-14` for
flexible bookings before `2027-01-01`, `flex-30` for later flexible bookings, and
`advance-nonrefundable` for advance purchase. `refundable_until` is the inclusive cancellation
deadline based on the current arrival date, or `null` for advance purchase. Rescheduling returns
both policy fields alongside the shifted arrival and departure dates.

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
appear in these totals.

`cash_converted_to_credit_cents` is cumulative cash exchanged for hotel credit. Credit liability
includes available credit and credit applied to active groups. Applying credit does not move cash
or reduce liability. Expiry of available credit and non-refundable consumption reduce liability.

## Cancel with hotel credit

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`.
An unsupported value is rejected with `invalid_operation`. Hotel credit on a non-refundable
cancellation is rejected with `refund_method_not_available`.

Refundable cash converted to hotel credit receives a 10% bonus, rounded to the nearest cent with
half-cents rounded up. Results include `credit_issued_cents` in addition to `refunded_cents`,
`retained_cents`, `group_id`, and `revision`. Both cash settlement amounts are zero on conversion.
Previously applied credit is restored to its original lots without a bonus. A restored amount
whose original expiry has passed is immediately consumed. On non-refundable cancellation,
cash is retained and applied credit is consumed.

## Apply hotel credit

`apply_hotel_credit` contains `operation_id`, `occurred_on`, `group_id`, and `amount_cents`,
and accepts `expected_revision`. It applies the guest's credit to an active group's outstanding
deposit, across properties. Lots are consumed by earliest expiry, then `source_operation_id`.
Expiry is evaluated on `occurred_on` and paused while credit funds an active group.

Validation follows cash payment rules; insufficient unexpired credit is rejected with
`insufficient_credit`. Results include `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Existence and revision checks precede domain
validation, and rejections change neither balances nor revisions.

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

Lots remain usable through the date 365 days after cancellation. Expired and exhausted lots
are omitted. Results are ordered by `expires_on`, then `source_operation_id`. A guest with no
available credit receives zero and an empty array.

Both this endpoint and `/api/v1/ledger` accept `on=YYYY-MM-DD`, defaulting to the current UTC
date. This date controls expiry of current balances; it does not reconstruct historical
transactions. Reads do not mutate balances. An invalid date returns `422` with
`{"error":{"code":"invalid_date"}}`.
