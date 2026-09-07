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
group it is addressed to, exactly once. Rejected operations do not increment revisions.
Payment reductions and chargebacks guard and return the revision of the original payment group;
other groups whose held cash changes also advance. Revoking a credit lot's entitlement leaves
groups holding that credit unchanged.

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

## Transfer applied deposit

Submit `transfer_deposit` through the batch endpoint with the common `operation_id`, `type`, and
`occurred_on` fields, plus:

```json
{
  "operation_id": "transfer-1",
  "type": "transfer_deposit",
  "occurred_on": "2026-10-03",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both revision guards are optional. Resolve source existence, then destination existence, then
check source and destination revisions in that order. Missing and stale errors identify the
relevant `group_id`; stale errors include `expected_revision` and `actual_revision`.

Groups must be distinct, active, and belong to the same guest. The amount must be positive integer
cents, covered by the source's held cash and credit, and fit the destination's outstanding deposit.
The complete operation is rejected with `invalid_transfer`, `group_not_active` (including the
inactive `group_id`), `invalid_amount`, `transfer_exceeds_held_funding`, or
`transfer_exceeds_outstanding` as appropriate.

Funding leaves the source's active rooms in reverse allocation creation order across cash and
credit. It fills the destination's active rooms in original room order, keeping the draw order and
each payment or credit-lot identity. Both groups advance one revision. Success returns:

```json
{
  "operation_id": "transfer-1",
  "status": "applied",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "source_outstanding_deposit_cents": 19000,
  "destination_outstanding_deposit_cents": 19000,
  "source_revision": 3,
  "destination_revision": 2
}
```

A transfer changes no ledger total, issues no bonus, and leaves applied credit expiry paused.
Later cancellation uses the destination's policy; refundable credit returns to its original lot
and expiry, subject to existing shortfall absorption. Reductions and chargebacks follow the
original payment's cash across groups, removing its newest held allocations first.

Transfers use the same durable retry contract as other operations: an equivalent retry returns
the exact stored result, and a changed payload returns `operation_id_conflict`.

## Read a payment

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` for an applied,
durably recorded cash payment. The statement includes `payment_operation_id`, `original_group_id`,
`recorded_cents`, and the six dispositions `held_cents`, `refunded_cents`, `retained_cents`,
`converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. Dispositions sum to recorded
cash, and all amounts are always present.

Once cash from a payment has participated in a transfer, its statement also includes:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

The list is ordered by `group_id`, omits groups without held cash, and sums to `held_cents`.
It becomes `[]` when no cash remains held. Payments never transferred omit this field.
Reads do not change state. A missing record returns `404` with `operation_not_found`; a record
that is not an applied cash payment returns `422` with `payment_not_reconcilable`.

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
