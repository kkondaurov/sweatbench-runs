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
another identifier. Revisions returned by an operation describe its explicitly addressed groups.
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

Submit `transfer_deposit` through the partner batch endpoint:

```json
{
  "operation_id": "transfer-1",
  "type": "transfer_deposit",
  "occurred_on": "2027-02-01",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both groups must be active, distinct, and belong to the same guest. Source existence is checked
before destination existence, then the optional source and destination revision guards are checked
in that order. Missing or inactive group errors include that group's `group_id`. A destination
revision mismatch uses the same `stale_revision` fields as a source mismatch.

The amount must be a positive integer, covered by the source's held cash and credit, and no greater
than the destination's outstanding deposit. Rejections use `invalid_transfer`, `group_not_active`,
`invalid_amount`, `transfer_exceeds_held_funding`, or `transfer_exceeds_outstanding` as applicable.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`, along with `operation_id` and `status`.

Funding is drawn from the newest source allocations first across cash and credit, then fills
active destination rooms in their original order. Cash retains its payment identity; credit retains
its original lot and paused expiry. Transfers change no ledger total. Later cancellation uses the
destination's policy. Transfers have the same durable retry and batch-order guarantees as other
operations.

## Transferred payment corrections and statements

`reduce_cash_payment` and `charge_back_payment` follow a payment's allocations across all groups,
removing held cash in reverse allocation order. Their `expected_revision` still guards the original
payment group, and their result's `revision` belongs to that original group. Every other group whose
accounting changes also increments its revision once. Credit clawbacks do not alter groups holding
credit from the revoked lot.

`GET /api/v1/payments/:payment_operation_id` adds `held_by_group` once any cash from that payment
has participated in a transfer. It lists `{ "group_id": "group-92", "amount_cents": 500 }` entries
ordered by `group_id`, omits zero balances, and sums to `held_cents`. It remains present as an empty
array after all held cash is settled or corrected. Payments that never participated in a transfer
retain their earlier statement shape. The original payment result is unchanged.
