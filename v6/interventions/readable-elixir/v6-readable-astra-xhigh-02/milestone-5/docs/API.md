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
group it addresses, exactly once. This includes operations that derive their group from another
identifier. Rejected operations do not increment revisions. Revision guards apply only to groups
explicitly addressed by a request.

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

### Transfer a deposit

Submit `transfer_deposit` in the operations array:

```json
{
  "operation_id": "transfer-17",
  "type": "transfer_deposit",
  "occurred_on": "2026-11-01",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "expected_revision": 3,
  "destination_expected_revision": 1
}
```

Both groups must be distinct, active reservations for the same guest. The positive integer amount
must fit the source's held deposit and the destination's outstanding deposit. Cash and hotel credit
move together in reverse allocation creation order, filling destination rooms in their original
order. Cash keeps its payment identity; credit keeps its lot and remains applied with expiry paused.
Transfers leave all ledger totals unchanged. Later cancellation uses the destination's policy.

The result contains:

```json
{
  "operation_id": "transfer-17",
  "status": "applied",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "source_outstanding_deposit_cents": 1000,
  "destination_outstanding_deposit_cents": 2000,
  "source_revision": 4,
  "destination_revision": 2
}
```

Existence is checked for the source and then destination, followed by the optional source and
destination revision guards, in that order. Missing or inactive group errors include the affected
`group_id`; a destination `stale_revision` reports its own `group_id`, `expected_revision`, and
`actual_revision`. Other transfer errors are `invalid_transfer`, `invalid_amount`,
`transfer_exceeds_held_funding`, and `transfer_exceeds_outstanding`.

Transfers share the durable retry contract: an equivalent payload with the same `operation_id`
returns the exact stored result, including both revisions. A different payload returns
`operation_id_conflict`. Earlier operations in the batch are visible to later transfers.

Cash reductions and chargebacks follow a payment's allocations across all groups, removing held
cash in reverse allocation order. Their `expected_revision` still guards the original payment
group, and their result's `revision` belongs to that group. Other changed groups also advance once.

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

## Read a payment

`GET /api/v1/payments/:payment_operation_id`

For an applied, durably recorded cash payment, `data` contains `payment_operation_id`,
`original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`,
`converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. All monetary fields are
present, including zeros; the six disposition amounts sum to `recorded_cents`.

Once any of the payment's cash participates in a transfer, the statement also includes:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Entries are ordered by `group_id`, omit zero balances, and sum to `held_cents`. The field remains
present as an empty array when no held cash remains. Payments never transferred omit this field.
Statement reads use a consistent snapshot and do not change state.

A missing durable record returns `404` with `operation_not_found`. A record that is not an applied
cash payment returns `422` with `payment_not_reconcilable`.
