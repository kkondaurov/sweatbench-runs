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
applied operation increments every group whose state it changes exactly once, and always the group
it is addressed to. This includes operations that derive their group from another identifier.
Rejected operations do not increment revisions. Reductions and chargebacks return the original
payment group's `revision` and outstanding deposit, even when the cash now funds other groups.

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

Submit `transfer_deposit` through the partner batch endpoint:

```json
{
  "operation_id": "transfer-17",
  "type": "transfer_deposit",
  "occurred_on": "2026-11-01",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 500,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both groups must be distinct, active, and belong to the same guest. Transfers move held cash and
hotel credit in reverse allocation creation order, filling active destination rooms in their
original order. Payment and credit-lot identities are preserved. Ledger totals, credit expiry,
and credit bonuses do not change.

The applied result includes `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`, alongside the usual `operation_id` and `status`.

Resolve source existence, then destination existence, then the optional source and destination
revision guards in that order. Missing and inactive group errors identify the affected `group_id`.
Either revision mismatch returns the usual `stale_revision` fields for that group. Domain errors are
`invalid_transfer`, `group_not_active`, `invalid_amount`, `transfer_exceeds_held_funding`, or
`transfer_exceeds_outstanding`. All failures leave both groups unchanged. Transfers use the same
durable retry and batch-order rules as other operations.

Later cancellations use the destination's policy. Reductions and chargebacks follow cash across
groups and increment every affected group's revision, while checking `expected_revision` only
against the original payment group.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id` returns the current cash dispositions described in
[room accounting and payment reductions](requests/04-room-accounting-and-payment-reductions.md).
Once any cash from the payment has been transferred, its statement also includes `held_by_group`:

```json
{
  "held_by_group": [
    {"group_id": "group-81", "amount_cents": 500},
    {"group_id": "group-92", "amount_cents": 500}
  ]
}
```

Entries are ordered by `group_id`, omit zero balances, and sum to `held_cents`. The field remains
present as an empty array after all cash is removed or settled. Payments that have never been
transferred omit it. Statements are read-only; original operation results remain immutable.

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
