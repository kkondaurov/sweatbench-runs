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

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

## Transferring deposit funding

A `transfer_deposit` operation moves part of the applied deposit between two active groups of the
same guest without moving money through a provider:

```json
{
  "operation_id": "op-9001",
  "type": "transfer_deposit",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 4000
}
```

An optional `expected_revision` guards the source group and `destination_expected_revision` guards
the destination. Funding leaves the source's most recent allocations (cash and hotel credit alike)
and fills the destination's active rooms in order, keeping each slice's payment or credit-lot
provenance. A transfer settles nothing: it computes no credit bonus, does not resume the expiry of
applied credit, and changes no ledger total. The groups must be distinct, active, and share a
`guest_id`. Rejections use `group_not_found` (with that group's `group_id`), `stale_revision`,
`invalid_transfer`, `group_not_active` (with that group's `group_id`), `invalid_amount`,
`transfer_exceeds_held_funding`, and `transfer_exceeds_outstanding`. The applied result contains
`source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`; both groups' revisions increment exactly once. Reductions and
chargebacks follow a payment's allocations wherever they currently fund rooms.

## Reconciling a payment

`GET /api/v1/payments/:payment_operation_id` returns the current disposition of one durably
recorded cash payment: `recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`,
`converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. Once any funding from the
payment has participated in a transfer, the statement also carries `held_by_group`: the payment's
held cash per group, ordered by `group_id`, omitting groups with no held cash and summing to
`held_cents`. A missing record returns `404` as `{"error":{"code":"operation_not_found"}}`; a
record that is not an applied cash payment returns `422` as
`{"error":{"code":"payment_not_reconcilable"}}`.
