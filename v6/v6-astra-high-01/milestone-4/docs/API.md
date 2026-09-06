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

## Room accounting and payment corrections

Rooms also contain `status`, `lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. Room lodging and deposit amounts describe the original room requirement;
cancelled rooms have zero held cash and credit. All group monetary totals sum active rooms only.
Funding fills active rooms in original room order, and follows operation processing order.

`cancel_rooms` accepts `group_id`, a nonempty `room_ids` array of distinct active room identifiers,
and optional `refund_method` (`cash` by default, or `hotel_credit`). It settles only those rooms
under the group's fixed cancellation policy. Its result contains `group_id`,
`cancelled_room_ids` in original room order, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. A credit bonus is rounded once on their combined cash.
Invalid room selections return `invalid_rooms`. Cancelling the last active room cancels the group;
`cancel_group` settles all remaining active rooms.

`reduce_cash_payment` accepts `payment_operation_id`, positive integer `amount_cents`, and optional
`expected_revision`. It removes only cash from that payment still held on active rooms, in reverse
fill order. The result contains `payment_operation_id`, the derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Errors are `operation_not_found`,
`payment_not_reducible`, `invalid_amount`, or `reduction_exceeds_held_cash`.

`charge_back_payment` accepts `payment_operation_id` and optional `expected_revision`. It reclassifies
all of that payment's cash except prior reductions as charged back, including previously refunded,
retained, and converted principal. Held cash is removed, reopening the deposit. Converted cash's
credit entitlement is revoked; credit already applied to other groups stays applied and can create
a credit shortfall. The result contains `payment_operation_id`, the derived `group_id`,
`charged_back_cents`, `outstanding_deposit_cents`, and `revision`. Errors are
`operation_not_found` or `payment_not_chargeable` (including a previously charged-back payment).
It works on active and cancelled groups and advances only the original group's revision.

These operations use the common `operation_id` and `occurred_on` fields, revision checks, and durable
retry rules. Original payment and settlement results remain unchanged. Legacy funding without a
durable payment identifier cannot be targeted.

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` for an applied cash
payment. The statement contains exactly `payment_operation_id`, `original_group_id`,
`recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`,
`reduced_cents`, and `charged_back_cents`. The six dispositions sum to the recorded amount. Missing
records return `404` / `operation_not_found`; other operation records return `422` /
`payment_not_reconcilable`. Reads do not change state.

The ledger additionally includes cumulative `cash_reduced_cents`, cumulative
`cash_charged_back_cents`, and current `credit_shortfall_cents`. Recorded cash equals held,
refunded, retained, converted, reduced, and charged-back cash. Credit shortfall is calculated per
lot as the lesser of its unrecovered clawback and credit still applied to active groups. Returning
credit absorbs unrecovered clawback before the excess becomes available or expires. Credit
liability includes applied credit even when it is covered by a shortfall.
