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
applied operation increments every group whose state it changes, and always its addressed group,
exactly once. This includes operations that derive their group from another identifier.
Rejected operations do not increment revisions. Payment reductions and chargebacks guard and return
the original payment group's revision, including when transferred cash affects other groups.

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

### Transfer applied deposits

`transfer_deposit` supplies `source_group_id`, `destination_group_id`, and `amount_cents`, along with
`operation_id` and `occurred_on`. It accepts `expected_revision` for the source and
`destination_expected_revision` for the destination. Both groups must be distinct, active, and belong
to the same guest; they may belong to different properties.

The operation moves the newest held allocations first, across cash and hotel credit, and fills the
destination's active rooms in their original order. Payment identities and credit lots follow the
funding. Ledger totals and credit expiry do not change. Both group revisions increment once.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`. It follows the normal durable retry contract.

Source existence, destination existence, source revision, and destination revision are checked in
that order. Missing or inactive group errors include the affected `group_id`; stale revisions use
the standard fields above. Other rejection codes are `invalid_transfer`, `invalid_amount`,
`transfer_exceeds_held_funding`, and `transfer_exceeds_outstanding`. See the
[transfer requirements](requests/05-deposit-transfers.md) for settlement and correction behavior.

### Reconcile transferred payments

`GET /api/v1/payments/:payment_operation_id` reports the current cash dispositions for a recorded
payment. Once its cash has participated in a transfer, the statement also includes `held_by_group`,
an array of `{ "group_id": "group-81", "amount_cents": 500 }` entries ordered by `group_id`.
Only positive held balances appear; their sum equals `held_cents`. The array remains present and is
empty once no held cash remains. Payments never transferred keep their existing response shape.

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
