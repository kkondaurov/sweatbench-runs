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
and always its addressed group. This includes operations that derive their group from another
identifier. Payment reductions and chargebacks guard and return the original payment group's
revision, even when transferred funding also changes other groups.
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

Submit `transfer_deposit` through the partner-batch endpoint:

```json
{
  "operation_id": "transfer-1",
  "type": "transfer_deposit",
  "occurred_on": "2027-04-01",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "expected_revision": 3,
  "destination_expected_revision": 1
}
```

Both groups must be distinct, active, and owned by the same guest. The amount must be positive,
covered by the source's held funding, and no greater than the destination's outstanding deposit.
Source existence is checked before destination existence, followed by the optional source and
then destination revision guards. Missing or inactive group errors identify that `group_id`;
either revision mismatch uses the usual stale-revision envelope.

Funding moves in reverse allocation creation order across cash and credit, filling destination
rooms in booking order. Payment and credit-lot provenance survive; transfers do not change ledger
totals or credit expiry. Later settlement uses the destination's policy, and provider corrections
follow cash across groups.

An applied result includes `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`, alongside `operation_id` and `status`. Both revisions increment once.
Transfers follow the existing durable retry and same-batch visibility rules.

`GET /api/v1/payments/:payment_operation_id` adds `held_by_group` once any cash from the payment
has been transferred. It is an array of `{"group_id": "group-81", "amount_cents": 500}` entries,
ordered by `group_id`, omitting zero balances. Its amounts sum to `held_cents`; it remains present
as an empty array after all held cash is gone. Payments never transferred retain their existing
statement shape.
