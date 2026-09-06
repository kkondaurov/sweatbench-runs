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

The same durable idempotency rule applies to every operation with an `operation_id`: an exact retry
returns the original stored result, and reusing an identifier with a different payload returns
`operation_id_conflict`.

Supported operation types are:

- `open_group`
- `record_cash_payment`
- `apply_hotel_credit`
- `reschedule_group`
- `cancel_group`
- `cancel_rooms`
- `reduce_cash_payment`
- `charge_back_payment`

`cancel_group` accepts optional `refund_method`, either `cash` or `hotel_credit`. `cancel_rooms`
contains `group_id`, `room_ids`, and the same optional `refund_method`; its applied result contains
`cancelled_room_ids`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`.

`reduce_cash_payment` contains `payment_operation_id`, `amount_cents`, and optional
`expected_revision`. It derives the addressed group from the original applied cash payment and
returns `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and
`revision`.

`charge_back_payment` contains `payment_operation_id` and optional `expected_revision`. It derives
the addressed group from the original applied cash payment and returns `payment_operation_id`,
`group_id`, `charged_back_cents`, `outstanding_deposit_cents`, and `revision`.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Group totals describe active rooms only. Each room contains `room_id`, `nightly_rate_cents`,
`lodging_total_cents`, `status`, `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. A missing group returns `404` as `{"error":{"code":"group_not_found"}}`.

## Read finance totals

`GET /api/v1/ledger`

The response starts with:

```json
{
  "data": {
    "cash_held_cents": 0,
    "cash_refunded_cents": 0,
    "cash_retained_cents": 0,
    "cash_converted_to_credit_cents": 0,
    "cash_reduced_cents": 0,
    "cash_charged_back_cents": 0,
    "credit_liability_cents": 0,
    "credit_shortfall_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

## Read a guest's credit

`GET /api/v1/guests/:guest_id/credit`

The response is `{"data": <credit summary>}` with `guest_id`, `available_cents`, and unexpired
non-exhausted `lots` ordered by `expires_on`, then `source_operation_id`.

## Read an operation result

`GET /api/v1/operations/:operation_id`

The response is `{"data": <stored result>}` for a durable operation. Missing operations return
`404` as `{"error":{"code":"operation_not_found"}}`.

## Read a payment reconciliation

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, the response is:

```json
{
  "data": {
    "payment_operation_id": "pay-17",
    "original_group_id": "group-81",
    "recorded_cents": 5000,
    "held_cents": 1000,
    "refunded_cents": 500,
    "retained_cents": 500,
    "converted_to_credit_cents": 1000,
    "reduced_cents": 500,
    "charged_back_cents": 1500
  }
}
```

Missing operations return `404` as `{"error":{"code":"operation_not_found"}}`. Durable records that
are not applied cash payments return `422` as `{"error":{"code":"payment_not_reconcilable"}}`.
