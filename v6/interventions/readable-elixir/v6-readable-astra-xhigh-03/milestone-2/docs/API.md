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
      "deposit_due_cents": 19500,
      "revision": 1
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

## Cancellation policies and rescheduling

The policy is fixed when a group is opened, using `occurred_on` as its original booking date:

| Rate plan | Booking date | `policy_version` | Refundable through |
| --- | --- | --- | --- |
| `flexible` | Before `2027-01-01` | `flex-14` | Arrival minus 14 days |
| `flexible` | On or after `2027-01-01` | `flex-30` | Arrival minus 30 days |
| `advance_purchase` | Any | `advance-nonrefundable` | Never |

Cancellation on `refundable_until` is refundable. `reschedule_group` shifts departure by the
same number of days and retains the policy version. Its applied result includes `group_id`,
`new_arrival_on`, `new_departure_on`, `policy_version`, `refundable_until`, and `revision`.

## Cancel a group

Submit `cancel_group` with `group_id` and an optional `refund_method` of `cash` (the default) or
`hotel_credit`. An unsupported value is rejected with `invalid_operation`.

For a refundable cancellation, cash is either refunded or converted into a hotel-credit lot for
the group's guest. A new lot includes a 10% bonus, rounded to the nearest cent with half cents
rounded upward. It is available through cancellation plus 365 days and expires the following day.
Its `source_operation_id` is the cancellation's unchanged operation identifier.

Previously applied credit returns to its original lots and expiry dates, without another bonus,
regardless of the chosen refund method. Restored credit whose expiry is already past is immediately
excluded from availability and credit liability.

For a non-refundable cancellation, cash is retained and applied credit is consumed. Requesting
`hotel_credit` in this case is rejected with `refund_method_not_available`; the group stays active.

An applied result contains `group_id`, `refunded_cents`, `retained_cents`, `credit_issued_cents`, and
`revision`. Credit conversion reports zero refunded and retained cash. Cancellation clears all
current due and paid deposit balances and changes the group status to `cancelled`.

## Apply hotel credit

Submit `apply_hotel_credit` with `group_id` and a positive integer `amount_cents`. Credit belongs
to the group's guest and can fund reservations at any property. The group must be active, and
the amount cannot exceed its outstanding deposit. These checks use the same errors as cash
payments: `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding`.

Insufficient unexpired credit is rejected with `insufficient_credit`. Expiry is evaluated using the
operation's `occurred_on`. Lots are consumed by earliest `expires_on`, then `source_operation_id`.
Credit's expiry is paused while it funds an active group.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
Revision validation precedes the new credit and refund-method rules, just as for cash payments.

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

`deposit_paid_cents` is the sum of cash and credit currently funding the deposit. The response also
includes `policy_version` and `refundable_until`; the deadline is `null` for advance purchase.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Read guest credit

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then `source_operation_id`.
A guest with no available credit receives `200` with `available_cents: 0` and `lots: []`.

## Read finance totals

`GET /api/v1/ledger?on=2028-05-02`

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
to refunded, retained, or converted to credit. `cash_converted_to_credit_cents` is cumulative original
cash converted, excluding the bonus. Unpaid deposit requirements are not cash and never appear in
these totals.

`credit_liability_cents` includes both available credit and credit in active deposits. Redemption
and refundable restoration preserve liability, except when restored credit has already expired.
Expiry and non-refundable consumption reduce liability.

Both guest-credit and ledger reads accept an optional `on=YYYY-MM-DD`, defaulting to the current
UTC date. It controls expiry of current balances; it does not replay a historical ledger or change
stored balances. An invalid date returns `422` as `{"error":{"code":"invalid_date"}}`.
