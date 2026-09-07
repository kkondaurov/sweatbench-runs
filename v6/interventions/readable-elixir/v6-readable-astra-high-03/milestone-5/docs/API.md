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
Rejected operations do not increment revisions. Transfers return both groups' revisions; reductions
and chargebacks return the original payment group's revision in `revision`.

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
  "occurred_on": "2026-10-04",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both groups must be distinct, active, and belong to the same guest. Each revision guard is optional.
The source's existence is resolved first, then the destination's, then the source revision and the
destination revision. Missing and inactive group errors include that group's `group_id`. A stale
destination uses the same `stale_revision` shape above with the destination's expected and actual
revision.

An applied result contains:

```json
{
  "operation_id": "transfer-17",
  "status": "applied",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "source_outstanding_deposit_cents": 15500,
  "destination_outstanding_deposit_cents": 18500,
  "source_revision": 3,
  "destination_revision": 2
}
```

Funding moves from the newest source room allocation first, regardless of whether it is cash or
credit, and fills active destination rooms in their original order. Cash retains its payment
identity; credit retains its original lot and paused expiry. Transfers change no ledger total and
issue no credit bonus. Later cancellations use the destination's policy.

Domain rejections use `invalid_transfer` for identical groups or different guests,
`group_not_active` for an inactive group, `invalid_amount` for an unusable amount,
`transfer_exceeds_held_funding` for insufficient source funding, and
`transfer_exceeds_outstanding` for insufficient destination capacity. No partial transfer occurs.
Transfers follow durable idempotency and same-batch visibility: an exact retry returns the original
result, including both revisions, without moving funding again.

Reductions and chargebacks follow a payment's held cash across groups in reverse allocation order.
Their `expected_revision` still guards only the original payment group; other groups whose funding
or cash settlement totals change also advance their revisions.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id`

The response is `{"data": <statement>}` for a durably recorded, applied cash payment. It includes
`payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. The six
dispositions sum to `recorded_cents`.

Once any cash from the payment has been transferred, the statement also includes `held_by_group`:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Entries are ordered by `group_id`, omit zero balances, and sum to `held_cents`. This field remains
present as an empty array after no cash is held. Payments never transferred omit the field.
Missing operations return `404` with `operation_not_found`; other stored operation types or rejected
payments return `422` with `payment_not_reconcilable`. Reading a statement does not change state.

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
