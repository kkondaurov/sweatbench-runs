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

`deposit_paid_cents` is the sum of cash and hotel credit currently funding the deposit. Cancellation
clears all three paid totals and the deposit due. The lodging total and room details remain readable.

Groups also include a fixed `policy_version`: `flex-14` for flexible bookings before `2027-01-01`,
`flex-30` for flexible bookings on or after that date, or `advance-nonrefundable`. Their
`refundable_until` is the arrival date minus 14 or 30 days for flexible groups, and `null` for
advance purchase. Cancellation on the deadline is refundable. Rescheduling preserves the policy
version and recomputes the deadline; its result includes both fields along with the new stay dates
and revision.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancel and issue hotel credit

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`. For a refundable
cancellation, cash is either refunded or converted into a credit lot with a 10% bonus rounded to
the nearest cent, with half-cents rounded upward. The cancellation operation ID becomes the lot's
`source_operation_id`. Credit remains available through 365 days after cancellation.

The applied result contains `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`,
and `revision`. Converting cash to credit returns zero refunded and retained cents. Previously
applied credit returns to its original lots and expiry without another bonus. Amounts restored
after their original expiry expire immediately. `credit_issued_cents` counts only newly issued
credit, including its bonus.

Non-refundable cancellation retains cash and consumes applied credit. Requesting hotel credit for
such a cancellation rejects with `refund_method_not_available`. An unrecognized refund method
rejects with `invalid_refund_method`. Rejections leave the group, credit and ledger unchanged.

## Apply hotel credit

`apply_hotel_credit` requires `group_id`, `amount_cents`, and the common operation fields. It applies
the group's guest's credit across properties, consuming lots by earliest expiry and then by
`source_operation_id`. Expiry is evaluated on the operation's `occurred_on` date. Applied credit
does not expire while funding an active group.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
The usual `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding` errors apply. An amount within the outstanding deposit that exceeds
the guest's available credit rejects with `insufficient_credit`. Revision checks precede these
domain rules, as with cash payments and cancellation.

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

Only unexpired lots with a remaining balance are returned, ordered by `expires_on` and then by
`source_operation_id`. A guest with no available credit returns zero and an empty array.

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
to refunded, retained, or the cumulative `cash_converted_to_credit_cents` total. The converted
total excludes the credit bonus. Unpaid deposit requirements are not cash and never appear in
these totals.

`credit_liability_cents` includes available credit and credit applied to active groups. Applying
or restoring unexpired credit does not change it. Available credit expiry, expired restoration,
and non-refundable consumption reduce it.

Both the guest-credit and ledger endpoints accept optional `on=YYYY-MM-DD` to evaluate expiry on
that date; the default is the current UTC date. This selects an expiry date for current balances,
not a replay of historical operations. Reads do not modify stored balances. An invalid `on`
returns `422` as `{"error":{"code":"invalid_date"}}`.
