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

Rooms now include `status`, `lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`,
and `credit_paid_cents`. Cancelled rooms remain in their original position. They have no deposit
due or held funding. Group lodging, due, paid, and outstanding totals include active rooms only.
New cash and credit fill available room deposits in original room order; cancellation and payment
corrections do not redistribute other funding.

The following operations use the common `operation_id` and `occurred_on` fields and the same durable
idempotency contract as other operations:

| Type | Additional fields | Applied result fields (besides operation ID, status, group ID, revision) |
| --- | --- | --- |
| `cancel_rooms` | `group_id`, nonempty `room_ids`, optional `refund_method` | `cancelled_room_ids`, `refunded_cents`, `retained_cents`, `credit_issued_cents` |
| `reduce_cash_payment` | `payment_operation_id`, positive integer `amount_cents` | `payment_operation_id`, `amount_cents`, `outstanding_deposit_cents` |
| `charge_back_payment` | `payment_operation_id` | `payment_operation_id`, `charged_back_cents`, `outstanding_deposit_cents` |

All three accept `expected_revision`. Payment corrections derive their group from the original
applied cash payment. Revision mismatches precede domain validation after resolving that payment's
group. A chargeback increments only the original payment group's revision, including when cancelled.

`cancel_rooms` rejects duplicates, missing rooms, cancelled rooms, and empty selections with
`invalid_rooms`. Successful results list rooms in original group order. Cancellation uses the group's
fixed policy and the existing cash or hotel-credit settlement rules, calculating one bonus on the
combined selected cash. Cancelling the last active room cancels the group. `cancel_group` settles
all remaining active rooms.

Reductions remove only the target payment's held cash, in reverse fill order. They reject missing
operations with `operation_not_found`, unusable targets with `payment_not_reducible`, invalid amounts
with `invalid_amount`, and amounts greater than the remaining held cash with
`reduction_exceeds_held_cash`.

Chargebacks reclassify all of a payment's cash except prior reductions. They reject missing operations
with `operation_not_found` and non-payments, rejected payments, fully reduced payments, or previously
charged-back payments with `payment_not_chargeable`. Refund and retention history is not performed
again. Converted credit entitlement is revoked from the original lots, removing unspent credit first.
The original payment's durable result never changes.

The ledger additionally exposes `cash_reduced_cents`, `cash_charged_back_cents`, and
`credit_shortfall_cents`. Shortfall is revoked credit still funding active deposits; it remains part
of `credit_liability_cents`. Returning credit absorbs unrecovered clawback before availability or
expiry is considered. The `on` parameter evaluates credit expiry, not a historical cash snapshot.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}`. A statement contains
exactly `payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`.
All monetary fields are present, including zeros. The six disposition amounts sum to `recorded_cents`.

A missing durable operation returns `404` with `operation_not_found`. An existing operation that is
not an applied cash payment returns `422` with `payment_not_reconcilable`. Legacy cash has no durable
payment identifier and cannot be reconciled or corrected through this endpoint.
