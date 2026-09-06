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
applied operation addressed to that group increments it exactly once and returns the resulting
revision. This includes operations that derive their group from another identifier. Rejected
operations do not increment it.

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

An `operation_id` is durably idempotent. The first operation received for an identifier is
processed normally and its result is stored. A later operation with the same identifier and an
equivalent JSON payload (object key order is irrelevant; array order and values are significant)
returns the exact stored result, including its revision or stale-revision details, without
re-applying anything. Reusing an identifier with a different payload is rejected with
`operation_id_conflict`. Rejected results are remembered like applied ones. The durable
idempotency rules apply to every operation type.

## Cancellation policy

Each group carries a fixed policy version chosen when it is opened:

- `flex-14`: flexible groups booked before `2027-01-01`; refundable through 14 days before arrival.
- `flex-30`: flexible groups booked on or after `2027-01-01`; refundable through 30 days before
  arrival.
- `advance-nonrefundable`: advance purchase groups; never refundable.

Rescheduling never changes a group's policy version. `refundable_until` is the last date on which
cancellation is refundable, or `null` for advance purchase.

`cancel_group` accepts an optional `refund_method`, `cash` (the default) or `hotel_credit`. A
refundable cancellation with `hotel_credit` converts the cash-funded portion of the deposit into a
credit lot worth 110% of that cash and reports it in `credit_issued_cents`; the cash is neither
refunded nor retained. Requesting `hotel_credit` for a non-refundable cancellation is rejected with
`refund_method_not_available`.

## Hotel credit

An `apply_hotel_credit` operation contains `group_id` and `amount_cents`. It redeems the group's
guest's unexpired credit into the group's outstanding deposit, consuming lots by earliest expiry
and then `source_operation_id`. The applied result contains `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Rejections use `group_not_found`, `group_not_active`,
`invalid_amount`, `payment_exceeds_outstanding`, or `insufficient_credit`.

Credit applied to an active group has its expiry paused while it funds that group. A refundable
cancellation restores it to its original lots; a non-refundable cancellation consumes it.

## Room-level accounting

Cash and credit fund active room deposits in the rooms' original order, filling one room's deposit
before moving to the next. New funding operations allocate in operation-processing order.

Funding from before durable operation records is carried forward as one unattributed senior block
per group: its aggregate cash is allocated first, then its hotel-credit lots in original
consumption order, all before funding represented by durable operation records. Recorded funding
is classified by the retained operation type and allocated in durable-record commit order,
regardless of `occurred_on`. Creating room allocations never changes any aggregate cash, credit,
or liability balance.

A group's lodging, due, paid, and outstanding totals describe its active rooms only.

## Settling selected rooms

A `cancel_rooms` operation contains `group_id`, `room_ids`, and the same optional `refund_method`
used by `cancel_group`. All supplied room identifiers must identify distinct, active rooms in the
group; otherwise the complete operation is rejected with `invalid_rooms`.

The selected rooms' allocated cash and credit are settled with the same date, policy, refund
method, bonus, and restoration rules as full cancellation, and their unpaid deposit ceases to be
due. Other rooms and their allocations are unchanged. The hotel-credit bonus is computed once on
the selected rooms' combined cash amount, not separately per room.

The applied result contains `group_id`, `cancelled_room_ids` in the group's original room order,
`refunded_cents`, `retained_cents`, `credit_issued_cents`, and `revision`. If no active rooms
remain, the group becomes `cancelled`. `cancel_group` settles only the remaining active rooms and
otherwise follows its existing contract.

## Reducing recorded cash

A `reduce_cash_payment` operation contains `payment_operation_id`, `amount_cents`, and an optional
`expected_revision`. It records a provider correction against one cash payment that has a durably
stored, applied result; the addressed group is the original payment's group.

Only cash from that payment that is still held on active rooms can be reduced. Held allocations
belonging to the payment are removed in reverse fill order, reopening the group's outstanding
deposit by the amount removed. Successive reductions compose against the remaining held cash; an
amount equal to the complete remaining held portion is valid.

Rejections use `operation_not_found` when no durable operation record exists for the identifier,
`payment_not_reducible` when the stored target can never accept a positive reduction,
`invalid_amount` for a non-positive reduction, and `reduction_exceeds_held_cash` when a smaller
positive amount could succeed. Funding from before durable operation records cannot be targeted
and returns `operation_not_found`.

The applied result contains `payment_operation_id`, `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. The target payment's stored result is never
rewritten: retrying the original payment returns its exact original result without reapplying
cash.

## Charging back a payment

A `charge_back_payment` operation contains `payment_operation_id` and an optional
`expected_revision`. It reverses all cash from one durably recorded payment except any portion
already recorded as reduced; the addressed group is the original payment's group. A payment can be
charged back whether its group is active or cancelled.

Rejections use `operation_not_found` when no durable record exists and `payment_not_chargeable`
when the record is not an applied cash payment, the payment has been fully reduced, or it was
already charged back.

Held allocations are removed in reverse fill order, reopening the active rooms' outstanding
deposit. Refunded and retained portions move to charged-back cash without reversing or reissuing
the historical settlement. Converted principal moves to charged-back cash and the credit
entitlement it created is revoked: the entitlement is removed from the lot's remaining balance
first, and any unrecovered portion becomes that lot's unrecovered clawback. If credit later
returns to a shortfalled lot, the returning credit extinguishes unrecovered clawback before any
amount becomes available.

A chargeback increments only the original payment group's revision, exactly once, and never
rewrites the original payment's stored result.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, `policy_version`, `refundable_until`, rooms in their original order, and
these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

Each room contains `room_id`, `nightly_rate_cents`, `status` (`active` or `cancelled`),
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. A missing group returns
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
`source_operation_id`. The optional `on=YYYY-MM-DD` query parameter reports expiry as of that
date; without it the current UTC date is used.

## Read an operation

`GET /api/v1/operations/:operation_id`

The response is `{"data": <result>}` where `<result>` is the stored result of the operation,
verbatim. A missing identifier returns `404` as `{"error":{"code":"operation_not_found"}}`.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment the response is:

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

Every amount is the current disposition of cash from that payment; the six disposition fields sum
exactly to `recorded_cents` and agree with the group, room, and ledger views. Reading a statement
never changes state. A missing durable operation record returns `404` as
`{"error":{"code":"operation_not_found"}}`; a record that is not an applied cash payment returns
`422` as `{"error":{"code":"payment_not_reconcilable"}}`.

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
to refunded, retained, or converted to credit. Provider corrections move held cash to reduced, and
chargebacks reclassify a payment's remaining dispositions to charged back. Recorded cash equals
held, refunded, retained, converted, reduced, and charged-back cash. Unpaid deposit requirements
are not cash and never appear in these totals.

`credit_liability_cents` is the credit owed to guests: available credit plus credit currently
applied to active groups, including credit covered by a current shortfall. `credit_shortfall_cents`
is the sum over lots of the lesser of each lot's unrecovered clawback and its credit still applied
to active groups. The optional `on=YYYY-MM-DD` query parameter reports credit expiry as of that
date; without it the current UTC date is used.
