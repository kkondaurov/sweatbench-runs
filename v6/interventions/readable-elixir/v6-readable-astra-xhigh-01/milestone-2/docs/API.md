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

`deposit_paid_cents` is the sum of its cash and hotel-credit portions. Cancellation clears the
deposit requirement and all three paid balances, while preserving the original lodging total.

Groups also contain a fixed `policy_version` and an inclusive `refundable_until` date:

| Rate plan and booking date | Policy version | Refundable through |
| --- | --- | --- |
| Flexible, before `2027-01-01` | `flex-14` | Arrival minus 14 days |
| Flexible, on or after `2027-01-01` | `flex-30` | Arrival minus 30 days |
| Advance purchase | `advance-nonrefundable` | `null` |

Rescheduling keeps the policy version and recomputes the deadline. The applied `reschedule_group`
result includes `policy_version` and `refundable_until` alongside the new stay dates and revision.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancel a group

`cancel_group` accepts `group_id` and an optional `refund_method`: `cash` (the default) or
`hotel_credit`. Other values are rejected with `invalid_operation`. The applied result includes
`group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`.

On a refundable cancellation, cash is either refunded or converted to a hotel-credit lot with a
10% bonus, rounded to the nearest cent with half-cents rounding upward. The lot belongs to the
group's guest, carries the cancellation's `source_operation_id`, and remains available through
365 days after cancellation. A date that would place the lot's expiry beyond `9999-12-31` is
unusable and receives `invalid_operation`. Converted cash is neither refunded nor retained as a fee.

Previously applied credit returns to its original lots without a new bonus or expiry extension.
If its original expiry has passed on the cancellation date, the restored portion expires
immediately. On a non-refundable cancellation, cash is retained and applied credit is consumed.
Requesting `hotel_credit` for a non-refundable cancellation rejects with
`refund_method_not_available` and leaves the group active, even if no cash was paid.

## Apply hotel credit

An `apply_hotel_credit` operation supplies `group_id` and a positive integer `amount_cents`.
It funds an active group's outstanding deposit using that guest's unexpired lots, in order of
`expires_on`, then `source_operation_id`. Expiry is evaluated on the operation's `occurred_on` date.
Credit can be used across properties.

The applied result includes `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
Existing payment errors apply: `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding`. A guest with too little usable credit receives `insufficient_credit`.
Missing required operation data receives `invalid_operation`. As with other group updates, a stale
revision is rejected before domain validation and all rejections leave balances and revisions unchanged.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit`

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then
`source_operation_id`. A guest with no available credit receives zero and an empty array.

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
to refunded, retained, or converted to credit. Those three settlement totals are cumulative.
Unpaid deposit requirements are not cash and never appear in these totals.

`credit_liability_cents` includes available credit and credit applied to active groups. Expiry is
paused while credit funds a group. Applying or restoring credit does not change liability, except
when restoration happens after its original expiry. Expiry and non-refundable consumption reduce
liability; cash conversion increases it by the issued credit including its bonus.

Both the guest-credit and ledger endpoints accept `?on=YYYY-MM-DD` to evaluate expiry on that date.
Omitting it uses the current UTC date. These reads evaluate the current stored balances; they do
not reconstruct historical payments or reservations, and `on` does not filter cumulative cash
totals. Reads never change credit balances. An unusable `on` value returns `422` as
`{"error":{"code":"invalid_date"}}`.
