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
dates, rate plan, policy version, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

`policy_version` is `flex-14`, `flex-30`, or `advance-nonrefundable` and is fixed when the group
is opened. `refundable_until` is the last date on which a flexible group can be cancelled
refundably (arrival minus its cancellation window); it is `null` for advance purchase.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

The response is:

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then by
`source_operation_id`.

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
to refunded, retained, or converted-to-credit. Unpaid deposit requirements are not cash and never
appear in these totals. `credit_liability_cents` includes both available credit and credit
currently applied to active groups.

## Expiry as of a date

The guest-credit and ledger endpoints accept an optional `on=YYYY-MM-DD` query parameter and
report credit expiry as of that date. Without it they use the current UTC date. An invalid date
returns `400` as `{"error":{"code":"invalid_date"}}`.

## Cancel and credit operations

`cancel_group` accepts an optional `refund_method`, either `cash` (the default) or
`hotel_credit`. Its applied result contains `group_id`, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. A refundable cancellation with `hotel_credit` converts the
cash portion into a credit lot worth 110% of that cash, available through the date 365 days after
cancellation. Requesting `hotel_credit` for a non-refundable cancellation is rejected with
`refund_method_not_available`.

`apply_hotel_credit` contains `group_id` and `amount_cents`. It redeems a guest's unexpired
credit into an active group's outstanding deposit, consuming lots by earliest expiry and then by
`source_operation_id`. Its applied result contains `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Rejections use `insufficient_credit` when the guest
cannot cover the amount, and the payment validation errors where they apply.

`reschedule_group` applied results also contain the group's fixed `policy_version` and its
recomputed `refundable_until`.
