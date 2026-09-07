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
applied operation increments the revision of every group whose state it changes, and always its
addressed group, exactly once. This includes operations that derive their group from another
identifier. Revision guards apply only to explicitly addressed groups.
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

Submit `transfer_deposit` through the partner batch endpoint with `operation_id`, `occurred_on`,
`source_group_id`, `destination_group_id`, and a positive integer `amount_cents`. Both groups must
be active, distinct, and belong to the same guest. The amount must fit within the source's held
cash and credit and the destination's outstanding deposit.

Optional `expected_revision` guards the source; `destination_expected_revision` guards the
destination. Existence is checked source first, then destination, followed by both revision guards
in the same order. Missing, inactive, and stale-group rejections identify the relevant `group_id`.
Other transfer errors are `invalid_transfer`, `invalid_amount`, `transfer_exceeds_held_funding`,
and `transfer_exceeds_outstanding`.

The applied result includes `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`. Both revisions advance once. Transfers are durably idempotent.

Funding moves in reverse allocation creation order across cash and credit, filling destination
rooms in original room order. Payment and credit-lot identities are preserved. Ledger totals,
credit expiry, and credit entitlements do not change. Later cancellations use the destination's
policy; payment reductions and chargebacks follow cash wherever it is held.

## Transferred payment statements and corrections

`GET /api/v1/payments/:payment_operation_id` adds `held_by_group` once cash from that payment has
participated in a transfer. This array contains `{ "group_id": "...", "amount_cents": 100 }`
entries ordered by `group_id`, omitting zero balances. It sums to `held_cents` and remains present
as an empty array after all held cash is gone. Payments never transferred retain their existing
statement shape.

Reductions and chargebacks guard the original payment group's revision and return its resulting
`revision` and `outstanding_deposit_cents`. Every other group whose funding or settlement counters
change also advances once. Groups funded by clawed-back credit keep their existing funding and
revision; the credit lot's shortfall accounts for the revoked entitlement.
