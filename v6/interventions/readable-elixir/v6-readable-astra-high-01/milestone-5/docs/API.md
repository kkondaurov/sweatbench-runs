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
applied operation increments the revision of every group whose state it changes exactly once,
including the group it is addressed to. This includes operations that derive their addressed group
from another identifier. Transfers return both revisions; reductions and chargebacks return the
original payment group's revision even when funding has moved elsewhere.
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

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

## Transfer an applied deposit

Submit `transfer_deposit` through the partner batch endpoint:

```json
{
  "operation_id": "transfer-18",
  "type": "transfer_deposit",
  "occurred_on": "2026-10-05",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both groups must be distinct, active, and belong to the same guest. The amount must be a positive
integer within the source's held deposit and the destination's outstanding deposit. Cash and credit
move together in reverse allocation creation order, filling destination rooms in their original
order. Cash keeps its payment identity; credit keeps its lot and paused expiry. Ledger totals do not
change. Later cancellation uses the receiving group's policy.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`, alongside the usual `operation_id` and `status`.

Existence is checked for the source and then the destination; `group_not_found` includes the missing
`group_id`. Both optional revision guards are then checked in that same order, before domain rules.
A destination mismatch has the usual `stale_revision` shape with the destination's `group_id`.
Other rejections are `invalid_transfer`, `group_not_active` (including the inactive `group_id`),
`invalid_amount`, `transfer_exceeds_held_funding`, or `transfer_exceeds_outstanding`.

Transfers are durably idempotent, including rejected attempts. Later operations in the same batch
see both groups' new balances and revisions.

## Reconcile transferred cash

`GET /api/v1/payments/:payment_operation_id` continues to report a payment's current cash
dispositions, wherever its allocations now reside. Once any of its cash has been transferred, the
statement also includes `held_by_group`, sorted by `group_id`:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Only groups holding a positive amount appear. The amounts sum to `held_cents`; an entirely settled
or corrected payment returns an empty list. Payments never involved in a transfer omit this field.

`reduce_cash_payment` and `charge_back_payment` follow held cash across groups, withdrawing newest
allocations first. Their optional `expected_revision` always guards the original payment group.
Each group whose cash accounting changes advances its revision once, as does the original payment
group. Credit-funded groups affected only by a lot's clawback keep their balances and revisions.
Original payment receipts and retry results remain unchanged.
