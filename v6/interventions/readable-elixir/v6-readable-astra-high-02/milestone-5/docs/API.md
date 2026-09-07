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
applied operation increments the revision of every group whose state it changes, and always the
group it is addressed to, exactly once. This includes operations that derive their group from
another identifier. Rejected operations do not increment revisions.

Payment reductions and chargebacks check `expected_revision` against the original payment group
and return that group's resulting `revision`. They follow cash allocations across transfers and
also increment affected groups' revisions; those additional groups have no revision guard.

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

## Transfer an applied deposit

Submit `transfer_deposit` through the batch endpoint with the common `operation_id` and
`occurred_on` fields, plus:

```json
{
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both revision guards are optional. Resolve source existence, then destination existence; check
the source revision, then the destination revision, before validating transfer rules. Missing or
inactive group errors identify the affected `group_id`. A destination `stale_revision` uses the
same error shape as a source mismatch.

Groups must be distinct, active, and belong to the same guest. The positive integer amount cannot
exceed source held funding or destination outstanding deposit. Rejections use `invalid_transfer`,
`group_not_active`, `invalid_amount`, `transfer_exceeds_held_funding`, or
`transfer_exceeds_outstanding` as applicable.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`, in addition to `operation_id` and `status`.

Transfers draw the newest held allocation first across cash and credit and fill destination rooms
in original room order. Payment and credit-lot provenance is preserved. No ledger total changes,
no bonus is issued, and applied credit expiry remains paused. Later cancellation uses the holding
group's policy. Transfers are durably idempotent and visible to subsequent operations in the batch.

For `GET /api/v1/payments/:payment_operation_id`, payments that have participated in a transfer
add `held_by_group`: an array of `{"group_id": "group-92", "amount_cents": 1000}` entries ordered
by `group_id`, omitting groups with zero held cash. The amounts sum to `held_cents`. This field
remains present as an empty array after all held cash is disposed of. Payments that have never
participated in a transfer retain their existing statement shape.

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
