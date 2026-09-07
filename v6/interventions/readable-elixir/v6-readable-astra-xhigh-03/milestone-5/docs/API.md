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
identifier. Rejected operations do not increment revisions.

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
  "operation_id": "transfer-1",
  "type": "transfer_deposit",
  "occurred_on": "2026-11-01",
  "source_group_id": "group-81",
  "destination_group_id": "group-92",
  "amount_cents": 1000,
  "expected_revision": 2,
  "destination_expected_revision": 1
}
```

Both groups must exist, be active, be distinct, and belong to the same guest. The amount must be a
positive integer within the source's held funding and the destination's outstanding deposit.
Funding moves from the most recently created source allocation first, across both cash and credit.
It fills active destination rooms in their original order, preserving draw order and each payment
or credit lot's identity. Transfers leave all ledger totals unchanged and keep applied credit's
expiry paused. Later cancellation uses the destination's policy.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`, alongside `operation_id` and `status`.

Validation resolves source existence, then destination existence, then the optional source and
destination revision guards, in that order. Missing and inactive group errors include the affected
`group_id`; destination stale revisions use the same stale response shape as source revisions.
Transfer rule failures use `invalid_transfer`, `group_not_active`, `invalid_amount`,
`transfer_exceeds_held_funding`, or `transfer_exceeds_outstanding`. Rejections leave both groups and
all funding unchanged. Exact retries return the stored original result under the durable operation
contract, including both revisions.

Payment reductions and chargebacks follow held cash across groups in reverse allocation order.
Their `expected_revision` still guards the original payment group, and their result's `revision`
belongs to that group. Other groups whose held funding changes also advance once.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id`

The `data` object contains `payment_operation_id`, `original_group_id`, `recorded_cents`, and the
six current dispositions: `held_cents`, `refunded_cents`, `retained_cents`,
`converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. Dispositions always sum to
the recorded amount. Reading a statement does not change state or the original payment result.

Once cash from a payment has participated in a transfer, its statement also includes:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

This list is ordered by `group_id`, omits zero balances, and sums to `held_cents`. It remains present
as an empty list when no cash remains held. Statements for payments never transferred omit this
field. A missing operation returns `404` with `operation_not_found`; a stored operation that is not
an applied cash payment returns `422` with `payment_not_reconcilable`.

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
