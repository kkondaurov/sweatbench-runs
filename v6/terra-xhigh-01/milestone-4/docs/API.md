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

Each room contains `room_id`, `nightly_rate_cents`, `status`, `lodging_total_cents`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Room status is `active` or
`cancelled`. Group lodging, due, paid, and outstanding totals sum active rooms only. A missing
group returns `404` as `{"error":{"code":"group_not_found"}}`.

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

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded, retained, or converted to hotel credit. Unpaid deposit requirements are not
cash and never appear in these totals. The response also includes cumulative
`cash_converted_to_credit_cents`, `cash_reduced_cents`, and `cash_charged_back_cents`, plus
`credit_liability_cents` and the current `credit_shortfall_cents`.

## Settle selected rooms

`cancel_rooms` is a submitted operation with `group_id`, `room_ids`, `occurred_on`, and optional
`refund_method` (`cash` by default or `hotel_credit`). Room identifiers must be distinct active
rooms. Its applied result contains `group_id`, `cancelled_room_ids` in the group's room order,
`refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`. Invalid selections are
rejected with `invalid_rooms`.

It uses the group's cancellation policy and settlement rules. Any hotel-credit bonus is calculated
once from all selected rooms' cash, not once per room. When the last active room is settled, the
group becomes cancelled. `cancel_group` settles only rooms which remain active.

## Correct or charge back a cash payment

`reduce_cash_payment` has `payment_operation_id`, positive `amount_cents`, and optional
`expected_revision`. It removes cash still held from that payment, newest room allocations first.
Its result contains `payment_operation_id`, derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`.

`charge_back_payment` has `payment_operation_id` and optional `expected_revision`. It reverses all
of that payment not already reduced, including cash previously refunded, retained, or converted to
credit. Its result contains `payment_operation_id`, derived `group_id`, `charged_back_cents`,
`outstanding_deposit_cents`, and `revision`.

Both operations use the original payment's group for revision checks. They are durably idempotent
like every submitted operation. Missing payment-operation records are `operation_not_found`.
Reductions also use `payment_not_reducible`, `invalid_amount`, and
`reduction_exceeds_held_cash`; chargebacks use `payment_not_chargeable`.

## Read a cash-payment statement

`GET /api/v1/payments/:payment_operation_id`

For an applied cash payment, returns its current disposition:

```json
{
  "data": {
    "payment_operation_id": "pay-17",
    "original_group_id": "group-81",
    "recorded_cents": 5000,
    "held_cents": 1000,
    "refunded_cents": 500,
    "retained_cents": 500,
    "converted_to_credit_cents": 1000,
    "reduced_cents": 500,
    "charged_back_cents": 1500
  }
}
```

All monetary fields are present and the six disposition amounts sum to `recorded_cents`. An unknown
operation returns `404` with `operation_not_found`; a remembered operation that is not an applied
cash payment returns `422` with `payment_not_reconcilable`.
