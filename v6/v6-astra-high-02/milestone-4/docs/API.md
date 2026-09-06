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
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Rooms retain their original order
and priced amounts after cancellation; their held cash and credit become zero. Group monetary
totals include active rooms only. New cash and credit fill active room deposits in their original
order, in operation-processing order. Group responses also include `cash_paid_cents`,
`credit_paid_cents`, `policy_version`, and `refundable_until`.

A missing group returns
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
to refunded, retained, or converted-to-credit cash, according to the settlement method. Unpaid deposit requirements are not cash and never appear in these
totals.


## Cancel selected rooms

`cancel_rooms` takes `group_id`, a nonempty `room_ids` array, and optional `refund_method`
(`cash` by default, or `hotel_credit`), in addition to `operation_id`, `type`, `occurred_on`, and
optional `expected_revision`. All selected rooms must be distinct and active; otherwise the entire
operation is rejected with `invalid_rooms`.

The existing cancellation policy and credit-restoration rules apply to the selected rooms. The
hotel-credit bonus is rounded once on their combined cash. Other room allocations remain in place.
The result includes `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`. Cancelling the last active room cancels the
group. `cancel_group` settles the remaining active rooms.

## Correct a cash payment

Both payment corrections take `payment_operation_id`, the common `operation_id`, `type`, and
`occurred_on` fields, and optional `expected_revision`. They derive their group from the original
payment and check that group's revision before domain validation. They do not require `group_id`.

- `reduce_cash_payment` also takes a positive integer `amount_cents`. It removes only the target
  payment's held cash, in reverse room fill order, and reopens outstanding deposit. The result
  includes `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and
  `revision`. Errors are `operation_not_found`, `payment_not_reducible`, `invalid_amount`, or
  `reduction_exceeds_held_cash`.
- `charge_back_payment` reclassifies every portion of an applied cash payment except prior
  reductions. It removes held cash and moves refunded, retained, and converted principal to
  charged-back cash. It also revokes the credit entitlement created by that principal. The result
  includes `payment_operation_id`, `group_id`, `charged_back_cents`, `outstanding_deposit_cents`,
  and `revision`. Errors are `operation_not_found` or `payment_not_chargeable` for a non-payment,
  rejected payment, fully reduced payment, or payment already charged back. The original group
  may be cancelled; only its revision advances, even when its credit funds other groups.

All operations, including these corrections and `cancel_rooms`, retain the durable idempotency
contract: equivalent retries return the exact stored result; changed payloads return
`operation_id_conflict`. The original payment's result never changes.

## Reconcile a cash payment

`GET /api/v1/payments/:payment_operation_id` returns `{"data": <statement>}` with exactly these
fields: `payment_operation_id`, `original_group_id`, `recorded_cents`, `held_cents`,
`refunded_cents`, `retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and
`charged_back_cents`. All amounts are present, including zero. The six current dispositions sum to
`recorded_cents`. This read does not change state.

A missing durable record returns `404` with `operation_not_found`; any record other than an applied
cash payment returns `422` with `payment_not_reconcilable`. Unattributed funding from before durable
operations cannot be addressed through payment endpoints or corrections.

## Credit and extended ledger totals

`GET /api/v1/guests/:guest_id/credit` returns the guest's `available_cents` and available `lots`,
ordered by expiry and source operation identifier. Each lot exposes `source_operation_id`,
`remaining_cents`, and `expires_on`. This endpoint and `/ledger` accept `on=YYYY-MM-DD` for expiry
evaluation, defaulting to the current UTC date.

The ledger also includes `cash_converted_to_credit_cents`, cumulative `cash_reduced_cents`,
cumulative `cash_charged_back_cents`, `credit_liability_cents`, and current
`credit_shortfall_cents`. Recorded cash is the sum of held, refunded, retained, converted, reduced,
and charged-back cash. Chargebacks change classifications without reissuing or reversing historical
provider refunds.

Credit liability includes available, unexpired credit and credit funding active rooms, including
credit covered by shortfall. A chargeback first removes its entitlement from the issuing lot's
remaining balance. The unrecovered portion is tracked per lot; current shortfall is capped at the
amount of that lot still funding active rooms. Refundable credit restoration absorbs unrecovered
clawback before its original expiry is checked. Only excess restored credit becomes available or
expires. Non-refundable consumption reduces applied credit and any current shortfall.

For shared credit lots, payment entitlements follow funding order, with legacy funding first.
Each entitlement is the difference between the 110% half-up-rounded values of cumulative converted
cash through that payment and before it. Calculation restarts for each issued lot; credit spending
remains fungible within a lot.
