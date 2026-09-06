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

Supported operation types are `open_group`, `record_cash_payment`, `reschedule_group`,
`cancel_group`, `apply_hotel_credit`, `cancel_rooms`, `reduce_cash_payment`, and
`charge_back_payment`. `cancel_rooms` settles selected rooms with the same date, policy, refund
method, bonus, and restoration rules as full cancellation. `reduce_cash_payment` records a
provider correction against one durably recorded cash payment and reopens its group's outstanding
deposit. `charge_back_payment` reverses all cash from one durably recorded payment except amounts
already reduced, reclassifying every remaining disposition and revoking the converted credit
entitlement.

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
dates, rate plan, status, and rooms in their original order. These totals describe active rooms only:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id`, `nightly_rate_cents`, `status` (`active` or `cancelled`),
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. A cancelled room carries no
requirement and no held funding. A missing group returns `404` as
`{"error":{"code":"group_not_found"}}`.

## Read finance totals

`GET /api/v1/ledger`

The response includes cash held on active reservations and every recorded disposition:

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

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted into hotel credit. Provider corrections add to reduced cash,
and chargebacks move remaining dispositions into charged-back cash. `credit_liability_cents` covers
available credit plus credit applied to active reservations;
`credit_shortfall_cents` is the current total of clawback entitlements that could not be
withdrawn from their lots, bounded by credit those lots still have applied to active reservations.
Unpaid deposit requirements are not cash and never appear in these totals.

## Reconciling a payment

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment the response is `{"data": {...}}` with the payment's
current dispositions: `payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`,
`refunded_cents`, `retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and
`charged_back_cents`. The disposition fields sum exactly to `recorded_cents`. A missing durable
record returns `404` as `{"error":{"code":"operation_not_found"}}`; a record that is not an
applied cash payment returns `422` as `{"error":{"code":"payment_not_reconcilable"}}`. Legacy
funding from before durable operation records has no identifier and cannot be read here.
