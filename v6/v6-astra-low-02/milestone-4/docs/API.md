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

## Read finance totals

`GET /api/v1/ledger`

The response starts with:

```json
{
  "data": {
    "cash_held_cents": 0,
    "cash_refunded_cents": 0,
    "cash_retained_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation settles that
cash as refunded, retained, or converted to hotel credit; provider corrections classify cash as
reduced or charged back. Unpaid deposit requirements are not cash and never appear in these totals.

## Room accounting and payment corrections

Room responses also contain `status`, `lodging_total_cents`, `deposit_due_cents`,
`cash_paid_cents`, and `credit_paid_cents`. Group totals include only active rooms.
Funding fills active room deposits in original room order; later funding fills any gaps
left by payment corrections.

The following operations use the same batch, revision, and durable retry contracts:

- `cancel_rooms`: supply `group_id`, a nonempty `room_ids` array of distinct active rooms,
  and optional `refund_method` (`cash` by default, or `hotel_credit`). The result includes
  `cancelled_room_ids` in original room order and `refunded_cents`, `retained_cents`,
  `credit_issued_cents`, and `revision`. It uses the group's fixed cancellation policy.
  Cancelling the final active room cancels the group. `cancel_group` settles all remaining
  active rooms.
- `reduce_cash_payment`: supply `payment_operation_id` and positive integer `amount_cents`.
  Only that payment's cash still held on active rooms can be reduced. The result includes
  `payment_operation_id`, the original `group_id`, `amount_cents`,
  `outstanding_deposit_cents`, and `revision`.
- `charge_back_payment`: supply `payment_operation_id`. All cash from that payment except
  previous reductions becomes charged-back cash, including cash already settled. Converted
  cash also revokes its share of the issued credit entitlement. The result includes
  `payment_operation_id`, the original `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`. The original group may be cancelled.

Both payment operations accept `expected_revision` for the original payment's group.
They leave the original payment's stored result intact. Chargebacks leave groups funded
by the affected hotel credit unchanged, including their revisions.

The ledger adds cumulative `cash_reduced_cents` and `cash_charged_back_cents`, plus current
`credit_shortfall_cents`. A credit shortfall is revoked entitlement still funding active
groups. It remains part of `credit_liability_cents` until settled or restored; returned
credit absorbs unrecovered clawback before becoming available or expiring.

## Read a payment

`GET /api/v1/payments/:payment_operation_id`

Returns `{"data": <statement>}` with exactly these fields:

- `payment_operation_id`
- `original_group_id`
- `recorded_cents`
- `held_cents`
- `refunded_cents`
- `retained_cents`
- `converted_to_credit_cents`
- `reduced_cents`
- `charged_back_cents`

The six disposition amounts sum to `recorded_cents`. Reading does not change state.
A missing durable record returns `404` with `operation_not_found`; a record that is not
an applied cash payment returns `422` with `payment_not_reconcilable`.

For reductions, an ineligible target returns `payment_not_reducible`, an unusable amount
returns `invalid_amount`, and an amount exceeding the remaining held cash returns
`reduction_exceeds_held_cash`. Chargebacks reject ineligible, fully reduced, or previously
charged-back payments with `payment_not_chargeable`. Both return `operation_not_found`
for a missing target record. Legacy unattributed funding has no targetable payment ID.
