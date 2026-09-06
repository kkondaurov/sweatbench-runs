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

### Apply hotel credit

`apply_hotel_credit` supplies `group_id` and positive integer `amount_cents`, along with
`operation_id`, `type`, and `occurred_on`. It applies the guest's available credit to the active
group's outstanding deposit, using expiry on `occurred_on`. Lots are consumed by earliest expiry,
then `source_operation_id`. Credit can be used across properties for the same guest.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.
It uses the cash-payment errors `group_not_found`, `group_not_active`, `invalid_amount`, and
`payment_exceeds_outstanding`, plus `insufficient_credit`. Missing required fields are
`invalid_operation`. The usual revision check precedes these domain rules.

### Cancellation and rescheduling

Flexible groups booked before `2027-01-01` use `flex-14`; later bookings use `flex-30`.
Advance-purchase groups use `advance-nonrefundable`. Policy is fixed at opening, including for
groups migrated from an earlier release. `reschedule_group` results include `policy_version` and
the recomputed `refundable_until`, in addition to shifted stay dates and `revision`.

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`. Other values
are rejected with `invalid_operation`. A refundable cancellation refunds its cash portion or
converts it to a credit lot with a 10% bonus rounded to the nearest cent, with half-cents upward.
New credit remains available through cancellation plus 365 days. Its `source_operation_id` is
the cancellation's `operation_id`.

Previously applied credit returns to its original lots without a new bonus. Any allocation whose
original expiry is past on the cancellation date expires immediately instead of becoming available.
For a non-refundable cancellation, cash is retained and applied credit is consumed. Requesting
hotel credit for a non-refundable cancellation rejects with `refund_method_not_available` and
leaves the group active.

Cancellation results contain `group_id`, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`. Cash converted to credit contributes zero to both refunded
and retained amounts. Cancelling clears the deposit requirement and both paid portions.

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

`deposit_paid_cents` is the sum of cash and credit currently applied to the deposit.
The group also includes `policy_version` and `refundable_until`. For flexible groups, the latter
is arrival minus 14 or 30 calendar days according to the fixed policy, inclusive for refundable
cancellation. It is `null` for advance purchase.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

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

Expired and exhausted lots are omitted; available lots are ordered by `expires_on`, then
`source_operation_id`. Guests without credit receive zero available cents and an empty lots array.
Credit applied to active groups is excluded from the available balance.

This endpoint and the ledger accept optional `on=YYYY-MM-DD`, defaulting to the current UTC date.
It evaluates expiry against current balances; it does not reconstruct historical transactions.
An invalid date returns `422` as `{"error":{"code":"invalid_date"}}`. Reads do not change balances.

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
to refunded, retained, or converted to credit. `cash_converted_to_credit_cents` counts original cash
cumulatively, excluding the credit bonus. Unpaid deposit requirements are not cash and never
appear in these totals.

`credit_liability_cents` includes available unexpired credit plus all credit applied to active
groups, where expiry is paused. Application and unexpired restoration preserve liability.
Expiry, restoration past the original expiry, and non-refundable consumption reduce it.
