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
applied operation increments the revision of every group whose state it changes, exactly once per
group, and always includes the group it is addressed to. This covers operations that derive their
group from another identifier, and operations such as deposit transfers or payment corrections that
change the state of groups other than the one addressed. Rejected operations do not increment any
revision.

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

## Transfer a deposit

A `transfer_deposit` operation moves applied deposit funding between two active groups of the same
guest without moving money through a provider. It carries `source_group_id`,
`destination_group_id`, and `amount_cents`, plus an optional `expected_revision` for the source
group and an optional `destination_expected_revision` for the destination group.

The amount is drawn from the source's active-room allocations in reverse allocation order,
regardless of funding kind, and fills the destination's active rooms in their original order,
preserving the order in which units were drawn. Each moved allocation keeps its provenance: cash
keeps its payment operation identity and hotel credit keeps its original lot. A transfer settles
and revalues nothing and changes no ledger total; it only changes which active rooms hold the
funding.

A rejected transfer uses `invalid_transfer` (the groups are the same or have different guests),
`group_not_active` (with that group's `group_id`), `invalid_amount`,
`transfer_exceeds_held_funding`, or `transfer_exceeds_outstanding`. Source existence is resolved,
then destination existence; a missing group returns `group_not_found` with that `group_id`. After
both groups exist, the source revision and then the destination revision are checked before these
rules, so a destination mismatch is reported as `stale_revision` with the destination's `group_id`.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`,
and `destination_revision`.

Once any funding of a recorded cash payment has participated in a transfer, its statement at
`GET /api/v1/payments/:payment_operation_id` adds `held_by_group`, ordered by `group_id` and
omitting groups without held cash; its amounts sum to `held_cents`, and it is empty once none
remains. Payments never involved in a transfer keep the earlier statement shape.

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
