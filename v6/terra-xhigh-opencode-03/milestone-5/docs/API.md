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

Every group has a positive integer `revision`. Opening a group creates revision `1`. Each applied
operation increments every group whose state it changes exactly once. This includes operations that
derive their group from another identifier and corrections that remove funding from another group.
The revision returned by a reduction or chargeback remains the original payment group's revision.
Rejected operations do not increment a revision.

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

## Transfer a deposit

`transfer_deposit` moves held cash and hotel credit between two distinct active groups for the same
guest. It does not move money through a provider and does not change ledger totals.

```json
{
  "operation_id": "transfer-1001",
  "type": "transfer_deposit",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "expected_revision": 3,
  "destination_expected_revision": 2
}
```

The source group is resolved before the destination group. After both exist, `expected_revision`
checks the source and `destination_expected_revision` checks the destination before transfer rules.
Both groups increment revision when the transfer applies. Transfers reject with `invalid_transfer`,
`group_not_active`, `invalid_amount`, `transfer_exceeds_held_funding`, or
`transfer_exceeds_outstanding` as applicable.

```json
{
  "operation_id": "transfer-1001",
  "status": "applied",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "source_outstanding_deposit_cents": 1200,
  "destination_outstanding_deposit_cents": 700,
  "source_revision": 4,
  "destination_revision": 3
}
```

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

## Read a payment

`GET /api/v1/payments/:payment_operation_id` returns the current statement for an applied cash
payment. Payments that have participated in a transfer add `held_by_group`, ordered by `group_id`.
It contains only active groups currently holding that payment's cash and may be empty after all of
its cash has settled or been corrected. Payments that have never participated in a transfer omit
this field.

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
