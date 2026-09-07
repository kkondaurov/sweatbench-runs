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

`cash_held_cents` is cash currently applied to active reservations. Cancellation refunds, retains,
or converts that cash to hotel credit. Provider corrections can classify cash as reduced or
charged back. Unpaid deposit requirements are not cash and never appear in these totals.

## Room accounting and partial cancellation

Each room also exposes `status`, `lodging_total_cents`, `deposit_due_cents`,
`cash_paid_cents`, and `credit_paid_cents`. Original room prices and deposit requirements
remain visible after cancellation; paid amounts then become zero. Group lodging, due,
paid, and outstanding totals sum active rooms only. Funding fills active rooms in their
original order; removing funding reopens that room's outstanding deposit without moving
any other allocations.

`cancel_rooms` takes `group_id`, a nonempty `room_ids` array of distinct active room
identifiers, and optional `refund_method` (`cash` by default, or `hotel_credit`). It
uses the group's fixed cancellation policy. The applied result contains `group_id`,
`cancelled_room_ids` in original room order, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. Hotel credit's 10% bonus is rounded once on the
combined selected cash. Applied credit returns to its original lots on refundable
settlement. Invalid selections reject the entire operation with `invalid_rooms`.
Cancelling the last active room cancels the group; `cancel_group` settles only the
remaining active rooms.

## Payment corrections

Both correction operations take `payment_operation_id` instead of `group_id`, plus
the common `operation_id` and `occurred_on` fields. Optional `expected_revision`
checks the original payment group's revision, and success advances only that revision.
They require a durably recorded, applied `record_cash_payment`. Original payment
results remain immutable, and corrections follow the same durable retry contract.

- `reduce_cash_payment` also takes positive integer `amount_cents`. It removes only
  cash from that payment still held on active rooms, in reverse fill order. Its result
  contains `payment_operation_id`, `group_id`, `amount_cents`,
  `outstanding_deposit_cents`, and `revision`. Rejections use `operation_not_found`,
  `payment_not_reducible`, `invalid_amount`, or `reduction_exceeds_held_cash`.
- `charge_back_payment` reverses all of that payment except previous reductions,
  including refunded, retained, or converted principal. Its result contains
  `payment_operation_id`, `group_id`, `charged_back_cents`,
  `outstanding_deposit_cents`, and `revision`. It is available on cancelled groups
  too. Missing targets use `operation_not_found`; other ineligible targets, fully
  reduced payments, and previously charged-back payments use `payment_not_chargeable`.

Chargeback reclassifies settled cash without reissuing or reversing historical money
movements. Converted cash loses its associated credit entitlement, including its bonus.
Unspent credit is revoked first. Any remaining clawback absorbs later credit
restorations before availability or expiry is considered. Credit already funding other
groups stays applied, and those groups' revisions do not change.

The ledger adds cumulative `cash_reduced_cents` and `cash_charged_back_cents`, and
current `credit_shortfall_cents`. Shortfall is unrecovered clawback capped per lot by
credit still applied to active groups. Applied credit remains in `credit_liability_cents`,
including shortfall. Recorded cash equals held, refunded, retained, converted, reduced,
and charged-back cash.

## Read one payment

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}`. A
statement contains exactly `payment_operation_id`, `original_group_id`, and these
integer-cent amounts, including zeros:

- `recorded_cents`
- `held_cents`
- `refunded_cents`
- `retained_cents`
- `converted_to_credit_cents`
- `reduced_cents`
- `charged_back_cents`

The six dispositions sum to `recorded_cents`. Reading a statement never changes state.
A missing durable record returns `404` with `operation_not_found`. A record that is
not an applied cash payment returns `422` with `payment_not_reconcilable`.
