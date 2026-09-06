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
group it is addressed to, exactly once. This includes operations that derive their addressed group
from another identifier. Single-group results return `revision`; transfers return both revisions
as described below.
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
`source_group_id`, `destination_group_id`, and positive integer `amount_cents`. Both groups must be
active, distinct, and belong to the same guest. The amount must fit within the source's held cash
and credit and the destination's outstanding deposit.

Optional `expected_revision` guards the source; `destination_expected_revision` guards the
destination. Existence is resolved source first, then destination, before checking those revisions
in the same order. Missing and inactive group errors identify the affected `group_id`.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`, alongside the usual operation identifier and status. Both revisions advance
once. Transfers are atomic and durably idempotent, including rejected results.

Funding is drawn from the newest source allocation first, across both cash and credit, and fills
the destination's active rooms in original room order. Payment identities and credit lots survive
the move. Transfers change no ledger totals, issue no bonus, and keep applied credit expiry paused.
Subsequent cancellation uses the destination's policy; restored credit retains its original expiry
and remains subject to existing shortfall absorption rules.

Transfer rejection codes are `invalid_transfer` for the same group or different guests,
`group_not_active`, `invalid_amount`, `transfer_exceeds_held_funding`, and
`transfer_exceeds_outstanding`, in addition to the standard existence, revision, and malformed
operation errors.

Reductions and chargebacks follow the original payment's cash across groups, removing held cash in
reverse allocation creation order globally. Each changed group and the addressed original payment
group increments its revision once. Only the original group is guarded by `expected_revision`, and
its resulting revision is returned in `revision`. Groups merely consuming credit from a revoked lot
remain unchanged.

## Read a payment after transfer

`GET /api/v1/payments/:payment_operation_id` retains the payment's original group, recorded amount,
and current held, refunded, retained, converted, reduced, and charged-back cash dispositions.
Once cash from a payment participates in a transfer, its statement also includes `held_by_group`:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Entries are ordered by `group_id`, omit zero balances, and sum to `held_cents`. The field remains
present as an empty array after all held cash is gone. Payments that never participated in a
transfer omit it. The original payment's stored operation result never changes.
