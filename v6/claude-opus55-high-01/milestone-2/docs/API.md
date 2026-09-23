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

### Operation types

| type | fields | applied result |
| --- | --- | --- |
| `open_group` | see the example above | `group_id`, `deposit_due_cents`, `revision` |
| `record_cash_payment` | `group_id`, `amount_cents` | `group_id`, `amount_cents`, `outstanding_deposit_cents`, `revision` |
| `apply_hotel_credit` | `group_id`, `amount_cents` | `group_id`, `amount_cents`, `outstanding_deposit_cents`, `revision` |
| `reschedule_group` | `group_id`, `new_arrival_on` | `group_id`, `new_arrival_on`, `new_departure_on`, `policy_version`, `refundable_until`, `revision` |
| `cancel_group` | `group_id`, optional `refund_method` | `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, `revision` |

Every operation also carries `operation_id`, `type`, and `occurred_on`. Operations addressed to an
existing group accept `expected_revision`.

### Cancellation policies

A group's `policy_version` is fixed when it is opened and never changes:

- `flex-14`: flexible groups booked before `2027-01-01`;
- `flex-30`: flexible groups booked on or after `2027-01-01`;
- `advance-nonrefundable`: advance-purchase groups.

`refundable_until` is the arrival date minus the 14- or 30-day window; cancelling on or before it is
refundable. It is `null` for `advance-nonrefundable`. Rescheduling recomputes it from the new
arrival date under the group's original policy.

### Hotel credit

`cancel_group` accepts `refund_method` `cash` (the default when omitted or `null`) or
`hotel_credit`. Any other value is rejected as `invalid_operation`. Requesting `hotel_credit` for a
non-refundable cancellation is rejected as `refund_method_not_available` and the group stays
active.

On a refundable cancellation with `hotel_credit`, the cash paid becomes a credit lot for the
group's guest worth the cash plus a 10% bonus (rounded to the nearest cent, half-cents upward).
The lot's `source_operation_id` is the cancellation's `operation_id`. It can be used through the
365th day after cancellation; `expires_on` is the following day, the first day it can no longer be
used. `credit_issued_cents` reports the lot's value; it is `0` otherwise.

`apply_hotel_credit` applies the group's guest's credit to the group's outstanding deposit. Lots
must be usable on the operation's `occurred_on` date and are consumed by earliest `expires_on`, then
by `source_operation_id`. Rejections, after `group_not_found`, `stale_revision`, and
`group_not_active`, are `invalid_amount`, `payment_exceeds_outstanding`, and then
`insufficient_credit`.

Credit applied to a group does not expire while that group is active. When the group is cancelled:

- refundably, the credit returns to its original lots with their original `expires_on` and no
  second bonus. If a lot's `expires_on` is on or before the cancellation date, that amount expires
  immediately instead;
- non-refundably, the credit is consumed.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, `policy_version`, `refundable_until`, status, rooms in their original order, and
these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents` (cash and hotel credit)
- `cash_paid_cents`
- `credit_paid_cents`
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
    "cash_retained_cents": 0,
    "cash_converted_to_credit_cents": 0,
    "credit_liability_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted to hotel credit. Unpaid deposit requirements are not cash and
never appear in these totals.

`credit_liability_cents` is hotel credit owed to guests: available credit whose lots have not
expired plus credit applied to active groups. Converted cash enters it with its bonus. Expiry and
non-refundable cancellations reduce it; applying credit and restoring it to an unexpired lot do not.

## Read a guest's credit

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

Lots are ordered by `expires_on`, then `source_operation_id`. Expired and exhausted lots, and credit
currently applied to active groups, are omitted. A guest without credit returns an empty list.

## Evaluating expiry

The guest-credit and ledger endpoints accept an optional `on=YYYY-MM-DD` query parameter and report
expiry as of that date; without it they use the current UTC date. A lot is expired on and after
its `expires_on`. The balances themselves are current; only expiry is evaluated as of `on`. An
unusable `on` value returns `400` as `{"error":{"code":"invalid_date"}}`.
