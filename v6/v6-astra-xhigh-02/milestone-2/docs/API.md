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
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

`deposit_paid_cents` is the sum of cash and credit currently applied to the deposit. Cancellation
clears these paid amounts and the deposit requirement.

Groups also include their fixed `policy_version` and `refundable_until`:

| Rate plan and booking date | Policy version | Refundable through |
| --- | --- | --- |
| Flexible, before 2027-01-01 | `flex-14` | Arrival minus 14 days |
| Flexible, on or after 2027-01-01 | `flex-30` | Arrival minus 30 days |
| Advance purchase | `advance-nonrefundable` | `null` |

Cancellation on `refundable_until` is refundable. Rescheduling preserves the policy and recomputes
the deadline from the new arrival. The `reschedule_group` result includes `policy_version` and
`refundable_until` alongside its dates and revision.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancellation and hotel credit operations

`cancel_group` accepts optional `refund_method: "cash"` (the default) or `"hotel_credit"`.
Its result includes `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and
`revision`. Invalid refund method values are rejected with `invalid_operation`.

For refundable cancellations, cash is either refunded or converted to a hotel credit lot worth
the cash plus a 10% bonus, rounded to the nearest cent with half cents rounded upward. The lot's
`source_operation_id` is the cancellation operation ID. It is available through cancellation plus
365 days and expires the following day. Converted cash is neither refunded nor retained as a fee.
Previously applied credit returns to its original lots and expiry dates, without another bonus;
amounts restored after their original expiry expire immediately.

For non-refundable cancellations, cash is retained and applied credit is consumed. Requesting
`hotel_credit` rejects with `refund_method_not_available` and leaves the group active.

`apply_hotel_credit` supplies `group_id` and positive integer `amount_cents`, along with the common
operation fields and optional `expected_revision`. It applies the guest's credit across properties,
using lots in order of expiry, then `source_operation_id`. Expiry is evaluated on `occurred_on`.
The result includes `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.

The existing `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding` errors apply. Missing required fields return `invalid_operation`;
insufficient unexpired credit returns `insufficient_credit`. Group existence and revision are
checked before these domain rules. Rejections change neither balances nor revisions.

## Read a guest's credit

`GET /api/v1/guests/:guest_id/credit?on=2028-05-02`

```json
{
  "data": {
    "guest_id": "guest-22",
    "available_cents": 5500,
    "lots": [
      {
        "source_operation_id": "cancel-17",
        "remaining_cents": 5500,
        "expires_on": "2028-05-02"
      }
    ]
  }
}
```

Only unexpired, nonempty lots appear, ordered by `expires_on`, then `source_operation_id`.
A guest without available credit returns `200` with zero availability and an empty list.

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
    "credit_liability_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or the cumulative `cash_converted_to_credit_cents` total. The converted
total excludes bonuses. Unpaid deposit requirements are not cash and never appear in these totals.

`credit_liability_cents` includes available credit and credit applied to active groups. Applied
credit pauses expiry until settlement. Redemption and refundable restoration preserve liability,
except when restored credit has already expired. Expiry and non-refundable consumption reduce it.

Both the ledger and guest-credit endpoints accept optional `on=YYYY-MM-DD` to evaluate expiry,
defaulting to the current UTC date. This projects expiry against current balances; it does not
reconstruct historical operation state. Reads do not mutate lots. Invalid dates return `422` as
`{"error":{"code":"invalid_date"}}`.
