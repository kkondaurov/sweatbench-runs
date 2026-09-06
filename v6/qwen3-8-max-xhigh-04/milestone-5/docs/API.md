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
resulting revision. This includes operations that derive their group from another identifier. An
applied operation also increments the revision of any other group whose funding it changes, such as
a group whose rooms lose funding to a reduction or chargeback that follows a transfer; those groups
are not guarded by the request's revision precondition. Rejected operations do not increment it.

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

Operations carrying an `operation_id` are durably idempotent. The first operation received for an
identifier commits its result together with its domain changes; a later retry with an equivalent
payload returns the exact stored result without touching the domain. Reusing an identifier with a
different payload is rejected with `operation_id_conflict`.

### Operation types

- `open_group` — creates a group reservation.
- `record_cash_payment` — applies cash to an active group's outstanding deposit.
- `reschedule_group` — moves an active group's stay to a new arrival date.
- `cancel_group` — settles the group's remaining active rooms and cancels it.
- `cancel_rooms` — settles a subset of a group's active rooms.
- `apply_hotel_credit` — redeems guest hotel credit into an active group's deposit.
- `reduce_cash_payment` — records a provider correction against one recorded cash payment.
- `charge_back_payment` — reverses all cash from one recorded cash payment.
- `transfer_deposit` — moves held funding between two active groups of the same guest.

### Deposit transfers

A `transfer_deposit` operation names `source_group_id`, `destination_group_id`, `amount_cents`, an
optional `expected_revision` for the source group, and an optional `destination_expected_revision`
for the destination group. Both groups must exist, be active, be distinct, and belong to the same
guest. Existence is resolved source first, then destination; both revision guards are checked
before the transfer rules.

Held funding is cash and hotel credit currently allocated to active rooms. The amount is drawn from
the source's held allocations in reverse allocation order, regardless of funding kind, and fills
the destination's active rooms in their original order, preserving the order in which units were
drawn. Cash keeps its payment operation identity and hotel credit keeps its original lot. A
transfer settles nothing, computes no bonus, resumes no expiry, and changes no ledger total.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`. Rejection codes are `invalid_transfer`, `group_not_active` (with the
inactive group's `group_id`), `invalid_amount`, `transfer_exceeds_held_funding`, and
`transfer_exceeds_outstanding`.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking
and stay dates, rate plan, `policy_version`, `refundable_until`, status, rooms in their original
order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

`policy_version` is `flex-14`, `flex-30`, or `advance-nonrefundable` and is fixed when the group is
opened. `refundable_until` is the last date on which a flexible group can be cancelled refundably;
it is `null` for advance purchase.

The group's lodging, due, paid, and outstanding totals describe its active rooms only. Each room
contains:

- `room_id`
- `nightly_rate_cents`
- `status` (`active` or `cancelled`)
- `deposit_due_cents`
- `cash_paid_cents`
- `credit_paid_cents`

A missing group returns `404` as `{"error":{"code":"group_not_found"}}`.

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

Expired and exhausted lots are omitted, ordered by `expires_on` then `source_operation_id`.

## Read finance totals

`GET /api/v1/ledger`

The response is:

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

`cash_held_cents` is cash currently funding active rooms. Cancellation moves that cash to refunded,
retained, or converted; provider corrections move it to reduced; chargebacks move it to
charged-back. Recorded cash always equals the sum of these six dispositions. Unpaid deposit
requirements are not cash and never appear in these totals.

`credit_liability_cents` includes available credit and credit currently applied to active groups,
including credit covered by a current shortfall. `credit_shortfall_cents` is the current shortfall
across credit lots.

Both this endpoint and the guest-credit endpoint accept an optional `on=YYYY-MM-DD` query parameter
and report credit expiry as of that date; without it they use the current UTC date.

## Read an operation

`GET /api/v1/operations/:operation_id`

The response is `{"data": <result>}`, the stored result of the remembered operation. A missing
operation returns `404` as `{"error":{"code":"operation_not_found"}}`.

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
exactly to `recorded_cents`. Reading a statement never changes state.

Once any funding from the payment has participated in a deposit transfer, the statement adds
`held_by_group`, ordered by `group_id`, listing each group currently holding cash from the payment:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Groups with no held cash are omitted and the amounts sum to `held_cents`; after none remains the
list is empty. Payments that have never participated in a transfer keep the earlier statement shape
without this field.

A missing durable record returns `404` as `{"error":{"code":"operation_not_found"}}`. A record that
exists but is not an applied cash payment returns `422` as
`{"error":{"code":"payment_not_reconcilable"}}`.
