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

A syntactically valid batch that completes returns `200` and one result per operation, in the same
order:

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

### Durable retries

An `operation_id` identifies the first submitted operation and its result across all groups and
operation types. Retrying the same JSON payload returns that original result, including rejections,
revisions, and stale-revision details, without consulting the current group or credit balances.
Object key order is irrelevant, including in nested objects. Array order, unknown fields, omitted
versus explicit defaults, and value types remain significant; integer cents differ from floats.

A different payload using an already recorded identifier returns
`{"operation_id":"<id>","status":"rejected","code":"operation_id_conflict"}`. It does not replace
the original submission or result. To correct a rejected operation, including its
`expected_revision`, submit a new operation identifier.

Each result and its domain changes commit together. A handled rejection changes no domain records
but retains the submitted operation and its result. Operations without a usable, nonblank string
identifier return `invalid_operation` without reserving a retry key. Concurrent retries have
at-most-once effects, and recorded results survive restarts.

An unexpected server fault returns `500` and aborts the rest of that batch. The failing operation
rolls back and has no stored result; earlier operations remain committed. Retrying the entire batch
therefore safely reuses the earlier outcomes and resumes processing the unrecorded operations.

This guarantee starts with operations first received by the durable-operations release. The gateway
uses a new identifier namespace at deployment; earlier accounting references are not backfilled.

### Revisions

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

For a first attempt, group existence is resolved before revision validation, so an operation naming
a missing group still returns `group_not_found`. Omitting `expected_revision` preserves the existing
unconditional behavior.

## Read an operation result

`GET /api/v1/operations/:operation_id`

The response is `{"data": <original result>}` for either an applied or rejected operation. A missing
record returns `404` as `{"error":{"code":"operation_not_found"}}`. Encode the unchanged partner
identifier as a URL path segment. This endpoint exposes only the result; retained submissions and
their first-commit order remain internal audit data.

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
