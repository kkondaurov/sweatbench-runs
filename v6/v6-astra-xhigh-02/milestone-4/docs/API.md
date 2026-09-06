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

Each room contains `room_id`, `nightly_rate_cents`, `status`, `lodging_total_cents`,
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Rooms remain in their original
order after cancellation. Cancelled rooms keep their original lodging amount and have zero due,
cash paid, and credit paid. All group totals describe active rooms only, including the lodging
total. Funding fills outstanding room deposits in original room order; cancelling or reducing
funding leaves other allocations in place.

Group responses also contain `cash_paid_cents`, `credit_paid_cents`, the fixed `policy_version`,
and `refundable_until`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Room cancellation and payment corrections

These operations use the common `operation_id`, `type`, and `occurred_on` fields and the same
durable retry and revision contracts as other operations:

- `cancel_rooms`: supplies `group_id`, a nonempty array of distinct active `room_ids`, and optional
  `refund_method` (`cash` by default, or `hotel_credit`). Settles only those rooms under the group's
  fixed cancellation policy. Returns `group_id`, `cancelled_room_ids` in original room order,
  `refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`. A credit bonus is rounded
  once on the combined cash. Invalid selections return `invalid_rooms`. Cancelling the last active
  room cancels the group; `cancel_group` settles all remaining active rooms.
- `reduce_cash_payment`: supplies `payment_operation_id` and positive integer `amount_cents`.
  Removes only the target payment's held cash in reverse fill order. Returns the payment identifier,
  derived `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`. Missing records
  return `operation_not_found`; ineligible or exhausted payments return `payment_not_reducible`.
  Other amount errors are `invalid_amount` and `reduction_exceeds_held_cash`.
- `charge_back_payment`: supplies `payment_operation_id`. Reclassifies all of the payment's cash
  except prior reductions as charged back, including settled cash, and revokes credit entitlements
  created by its converted cash. Returns the payment identifier, derived `group_id`,
  `charged_back_cents`, `outstanding_deposit_cents`, and `revision`. Missing records return
  `operation_not_found`; ineligible, fully reduced, or already charged-back payments return
  `payment_not_chargeable`. The original group may be active or cancelled.

Both payment operations derive their group for `expected_revision`; they do not require `group_id`.
Chargebacks increment only that group's revision and preserve any other groups funded by its credit.
Historical partner results, including original payment results, remain unchanged.

## Read a payment statement

`GET /api/v1/payments/:payment_operation_id`

Returns `{"data": <statement>}` for a durably recorded applied cash payment. The statement has
exactly `payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`, `refunded_cents`,
`retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and `charged_back_cents`. All amounts
are always present. The six disposition amounts sum to `recorded_cents`.

A missing record returns `404` with `operation_not_found`. An existing record that is not an applied
cash payment returns `422` with `payment_not_reconcilable`. Legacy funding without a durable payment
identifier cannot be read or corrected by payment identifier.

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

The ledger also includes `cash_converted_to_credit_cents`, `cash_reduced_cents`,
`cash_charged_back_cents`, `credit_liability_cents`, and `credit_shortfall_cents`.
Recorded cash equals held, refunded, retained, converted, reduced, and charged-back cash combined.
Chargebacks reclassify prior refunds and retentions without initiating another movement of money.

Credit liability includes available credit and credit applied to active rooms. A chargeback removes
its entitlement from an issued lot's remaining balance first; the unrecovered amount can create a
shortfall against credit from that lot still applied to active rooms. Returning credit absorbs that
unrecovered amount before any excess becomes available or expires. Non-refundable credit settlement
reduces both applied liability and any current shortfall it covered.

The ledger and `GET /api/v1/guests/:guest_id/credit` accept `on=YYYY-MM-DD` to evaluate expiry,
defaulting to the current UTC date. Applied credit remains a liability through its original expiry.
