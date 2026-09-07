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

Group monetary totals now describe active rooms only. Every room includes `status`,
`lodging_total_cents`, `deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents` alongside
its original identifier and nightly rate. Cancelled rooms retain their original lodging and deposit
requirement, have no held funding, and contribute nothing to group totals. Cash and credit fill
active rooms in original room order; settlement and corrections do not move other funding.

`cancel_rooms` accepts `group_id`, a nonempty `room_ids` array of distinct active rooms, and optional
`refund_method` (`cash` by default, or `hotel_credit`). It uses the group's fixed cancellation policy
and settles only the selected funding. Its result includes `group_id`, `cancelled_room_ids` in
original room order, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`.
The credit bonus is calculated once on the combined selected cash. Cancelling the last active room
cancels the group; `cancel_group` settles all remaining active rooms.

The following operations derive their group from `payment_operation_id` and accept optional
`expected_revision`. Like all operations they require `operation_id`, `type`, and `occurred_on`.

- `reduce_cash_payment` also requires a positive integer `amount_cents`. It removes only the target
  payment's held cash, in reverse fill order, reopening outstanding deposit. Its result includes
  `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
- `charge_back_payment` reverses all of a payment except previously reduced cash, including cash
  already refunded, retained, or converted to credit. It can address a cancelled group. Its result
  includes `payment_operation_id`, `group_id`, `charged_back_cents`, `outstanding_deposit_cents`, and
  `revision`. It increments only the original payment group's revision.

Missing target records use `operation_not_found`. Reductions use `payment_not_reducible` for
non-payments, rejected payments, and payments without held cash; otherwise unusable amounts use
`invalid_amount`, and excessive amounts use `reduction_exceeds_held_cash`. Chargebacks use
`payment_not_chargeable` for non-payments, rejected payments, fully reduced payments, and payments
already charged back. A stale revision on an applied payment takes precedence over these amount
and disposition checks.

Chargebacks reclassify historical cash without reissuing or undoing guest refunds. Converted cash
also revokes its share of each issued credit lot, including its incremental rounded bonus. Revocation
consumes the lot's remaining balance first. Any unrecovered entitlement absorbs future restorations
before expiry is considered. Credit already applied to other groups keeps funding those rooms and
remains a liability; their revisions do not change.

All three operations obey durable idempotency, including remembered rejections and exact retries.
The original cash payment's stored result remains unchanged after settlements and corrections.

### Read a payment statement

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` with exactly these fields:

- `payment_operation_id`, `original_group_id`;
- `recorded_cents`, `held_cents`, `refunded_cents`, `retained_cents`,
  `converted_to_credit_cents`, `reduced_cents`, `charged_back_cents`.

All monetary fields are always present. The six current dispositions sum to `recorded_cents`.
A missing operation returns `404` with `operation_not_found`; an existing operation that is not an
applied cash payment returns `422` with `payment_not_reconcilable`. Reads never modify state.
Legacy funding without a durable operation identifier cannot be targeted or reconciled.

The ledger additionally includes cumulative `cash_reduced_cents`, cumulative
`cash_charged_back_cents`, and current `credit_shortfall_cents`. Total recorded cash equals held,
refunded, retained, converted, reduced, and charged-back cash. Shortfall is the sum, for each lot,
of the lesser of its unrecovered clawback and credit still applied to active groups. The ledger's
`on` parameter controls available credit expiry; it does not select a historical cash snapshot or
remove credit currently applied to active groups from liability or shortfall.
