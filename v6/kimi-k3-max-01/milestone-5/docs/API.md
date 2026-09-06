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

## Additional operation types

Beyond `open_group`, `record_cash_payment`, `reschedule_group`, `cancel_group`, and
`apply_hotel_credit`, the batch endpoint supports:

- `cancel_rooms` with `group_id`, `room_ids`, and an optional `refund_method`, settling the
  selected active rooms the way full cancellation settles the whole group. The result contains
  `group_id`, `cancelled_room_ids`, `refunded_cents`, `retained_cents`, `credit_issued_cents`,
  and `revision`.
- `reduce_cash_payment` with `payment_operation_id`, `amount_cents`, and an optional
  `expected_revision`, removing held cash allocated by one durable payment. The result contains
  `payment_operation_id`, the derived `group_id`, `amount_cents`, `outstanding_deposit_cents`,
  and `revision`.
- `charge_back_payment` with `payment_operation_id` and an optional `expected_revision`,
  reversing every remaining disposition of one durable payment. The result contains
  `payment_operation_id`, the derived `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`.
- `transfer_deposit` with `source_group_id`, `destination_group_id`, `amount_cents`, and the
  optional guards `expected_revision` and `destination_expected_revision`, moving held cash or
  hotel credit between two active groups of the same guest. The result contains
  `source_group_id`, `destination_group_id`, `amount_cents`, `source_outstanding_deposit_cents`,
  `destination_outstanding_deposit_cents`, `source_revision`, and `destination_revision`.

Applied operations increment the revision of every group whose state they change, and always
the group explicitly addressed by the request.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`,
booking and stay dates, rate plan, status, policy version, `refundable_until`, and rooms in
their original order. Each room contains `room_id`, `nightly_rate_cents`, `status`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. The group totals describe
active rooms only:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

A missing group returns `404` as `{"error":{"code":"group_not_found"}}`.

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
    "cash_reduced_cents": 0,
    "cash_charged_back_cents": 0,
    "credit_liability_cents": 0,
    "credit_shortfall_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Settlement moves it to
refunded, retained, or converted to hotel credit; provider corrections move it to reduced or
charged-back cash. Unpaid deposit requirements are not cash and never appear in these totals.

`GET /api/v1/ledger` and `GET /api/v1/guests/:guest_id/credit` accept an optional
`on=YYYY-MM-DD` query parameter; expiry (and the liability) is evaluated as of that date,
defaulting to the current UTC date.

## Read payment statements

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, returns every current disposition of its cash:
`payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`,
which always sum to `recorded_cents`. Once any funding from the payment has participated in a
deposit transfer, the statement adds `held_by_group`, listing the cash still held by each
group ordered by `group_id`. A missing durable record returns `404` with
`{"error":{"code":"operation_not_found"}}`; a record that is not an applied cash payment
returns `422` with `{"error":{"code":"payment_not_reconcilable"}}`.
