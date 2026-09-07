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
`deposit_due_cents`, `cash_paid_cents`, and `credit_paid_cents`. Room status is `active` or
`cancelled`. Room lodging and deposit amounts retain the original quote; funding amounts describe
currently held cash and applied credit. Group totals sum only active rooms, so a fully cancelled
group has zero lodging, due, paid, and outstanding totals. Cash and credit fill active room deposits
in original room order, following the order in which funding operations are processed.

Groups also include `cash_paid_cents`, `credit_paid_cents`, their fixed `policy_version`, and
`refundable_until`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancel selected rooms

`cancel_rooms` supplies `group_id`, a nonempty `room_ids` array, and optionally `refund_method`
(`cash`, the default, or `hotel_credit`) and `expected_revision`, alongside the common operation
identifier and date. Every room must be distinct and active in that group; invalid selections reject
the whole operation with `invalid_rooms`.

The selected rooms settle under the group's fixed cancellation policy. Refundable cash is refunded
or converted to credit with a 10% bonus, rounded once on the selected rooms' combined cash. Applied
credit returns to its original lots, subject to clawback absorption and expiry. Non-refundable cash
is retained and credit consumed; requesting hotel credit is then rejected with
`refund_method_not_available`.

The result contains `group_id`, `cancelled_room_ids` in original room order, `refunded_cents`,
`retained_cents`, `credit_issued_cents`, and `revision`. Cancelling the final active room closes the
group. `cancel_group` settles all remaining active rooms using its existing result format.

## Correct a cash payment

Both correction operations supply `payment_operation_id`, `occurred_on`, their own `operation_id`,
and optionally `expected_revision`. The addressed group comes from the stored applied cash payment;
its revision is checked before other domain rules. Only that group's revision advances.

- `reduce_cash_payment` also supplies a positive integer `amount_cents`. It removes only the
  target's cash still held on active rooms, starting with its last-filled portions. The result
  contains `payment_operation_id`, `group_id`, `amount_cents`, `outstanding_deposit_cents`, and
  `revision`. Rejections use `payment_not_reducible` for an ineligible or exhausted target,
  `invalid_amount` for an unusable amount, and `reduction_exceeds_held_cash` for a positive amount
  exceeding the target's remaining held cash.
- `charge_back_payment` reclassifies every unreduced portion, including refunded, retained, and
  converted cash. It can address a cancelled group. Its result contains `payment_operation_id`,
  `group_id`, `charged_back_cents`, `outstanding_deposit_cents`, and `revision`. Ineligible, fully
  reduced, and previously charged-back payments reject with `payment_not_chargeable`.

A missing target record rejects with `operation_not_found`. Funding predating durable records is
unattributed and cannot be targeted. Corrections and room cancellations are durably idempotent;
they never change the original payment's stored result or initiate provider transfers.

Converted principal carries a fixed credit entitlement in each issued lot, including its share of
the rounded bonus. Chargebacks revoke that entitlement from the lot's available balance first.
Unrecovered clawback absorbs future refundable restorations before expiry is evaluated. Credit
already funding other groups remains applied and those groups' revisions do not change.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id` returns exactly these fields for a durably recorded,
applied cash payment:

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

All monetary fields are always present. The six current dispositions sum to `recorded_cents`.
A missing record returns `404` with `operation_not_found`; an existing record that is not an applied
cash payment returns `422` with `payment_not_reconcilable`. Reads do not change state.

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
to refunded, retained, or converted to credit. Unpaid deposit requirements are not cash and never appear in these
totals.

The six cash totals partition all recorded cash. Chargebacks move prior refunded, retained, or
converted amounts into `cash_charged_back_cents`, without repeating or reversing historical guest
refunds. Reduced and charged-back totals are cumulative.

`credit_liability_cents` includes unexpired available credit and all credit applied to active rooms.
`credit_shortfall_cents` sums, per lot, the smaller of unrecovered clawback and credit still applied
to active rooms. Applied credit remains a liability even when covered by a shortfall.

The ledger and `GET /api/v1/guests/:guest_id/credit` accept `on=YYYY-MM-DD` for expiry evaluation,
defaulting to the current UTC date. These are current balances evaluated for expiry on that date,
not historical account reconstructions. Guest credit returns available, unexpired lots ordered by
expiry and then `source_operation_id`.
