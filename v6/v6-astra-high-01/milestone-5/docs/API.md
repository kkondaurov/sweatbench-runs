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
another identifier. Payment reductions and chargebacks guard and return the revision of the
original payment group, even when they also update funding and revisions in other groups.
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

## Transfer a deposit

Submit `transfer_deposit` through the partner batch endpoint with `source_group_id`,
`destination_group_id`, and a positive integer `amount_cents`, plus the common `operation_id`,
`type`, and `occurred_on` fields. Both groups must be distinct, active, and belong to the same guest.
Optional `expected_revision` guards the source; `destination_expected_revision` guards the destination.
Source existence, destination existence, source revision, and destination revision are checked in
that order before transfer rules. Missing or inactive group errors identify that `group_id`.

Funding is drawn from the newest source allocations first, across cash and credit, and fills active
destination rooms in their original order. Payment identities and credit lots are preserved.
Transfers leave all ledger totals unchanged; applied credit retains its paused expiry. Later
settlement uses the destination's cancellation policy. See
[the deposit transfer request](requests/05-deposit-transfers.md) for rejection codes and settlement rules.

An applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`, alongside `operation_id` and `status`. Both revisions increment once.
Durable retries return the original result, including both revisions.

Once cash from a payment participates in a transfer, `GET /api/v1/payments/:payment_operation_id`
also returns `held_by_group`: a list of `{ "group_id": "...", "amount_cents": 500 }` entries ordered
by `group_id`. Only groups still holding that payment's cash appear; their amounts sum to
`held_cents`. The list remains present and empty when no held cash remains. Payments that have
never participated in a transfer retain their previous statement shape.
