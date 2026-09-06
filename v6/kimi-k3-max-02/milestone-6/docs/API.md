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

### Deposit transfers

A `transfer_deposit` operation moves part of the held deposit (cash and hotel credit allocated
to active rooms) from a `source_group_id` to a `destination_group_id`. Both groups must exist,
be active, be distinct, and belong to the same guest. It accepts an optional `expected_revision`
for the source and `destination_expected_revision` for the destination, and rejects with
`invalid_transfer`, `group_not_active`, `invalid_amount`, `transfer_exceeds_held_funding`, or
`transfer_exceeds_outstanding`. The applied result contains `source_group_id`,
`destination_group_id`, `amount_cents`, `source_outstanding_deposit_cents`,
`destination_outstanding_deposit_cents`, `source_revision`, and `destination_revision`. A transfer
changes no ledger total; it only changes which active rooms hold the funding, and it increments
the revision of every group whose state it changes.

### Finance reporting

A `start_finance_reporting` operation supplies `starts_on` as an ISO 8601 date. It addresses no
group and has no revision guard. The first applied start enables reporting; the financial state
immediately before it becomes the opening position on `starts_on`. Its applied result contains
exactly `operation_id`, `status`, and `starts_on`. A later, different start operation is rejected
with `reporting_already_started`; an invalid or missing `starts_on` is rejected with
`invalid_reporting_date`.

## Read a group

`GET /api/v1/groups/:group_id`

The response is `{"data": <group>}`. A group contains its partner identifiers, `revision`, booking and stay
dates, rate plan, status, rooms in their original order, and these totals:

- `lodging_total_cents`
- `deposit_due_cents`
- `deposit_paid_cents`
- `outstanding_deposit_cents`

Group totals are sums of the active rooms. Each room contains `room_id`, `nightly_rate_cents`,
`status` (`active` or `cancelled`), `deposit_due_cents`, `cash_paid_cents`, and
`credit_paid_cents`. Cash and credit fund active room deposits in the rooms' original order,
filling one room's deposit before moving to the next. A missing group returns `404` as
`{"error":{"code":"group_not_found"}}`.

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
to either refunded or retained (or, when hotel credit is chosen, converted to credit); a provider
reduction or chargeback moves it to reduced or charged-back. Recorded cash always equals the sum
of the six cash dispositions. Unpaid deposit requirements are not cash and never appear in these
totals. The ledger and the guest-credit endpoint accept an optional `on=YYYY-MM-DD` parameter and
report credit expiry as of that date; a malformed value returns `422` as
`{"error":{"code":"invalid_date"}}`.

## Reconcile a payment

`GET /api/v1/payments/:payment_operation_id`

For a durably recorded, applied cash payment, returns `{"data": <statement>}` with the current
disposition of every recorded cent:

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

The six disposition fields sum exactly to `recorded_cents`. Once any funding from the payment has
participated in a deposit transfer, the statement adds `held_by_group`, ordered by `group_id`,
with one `{"group_id": ..., "amount_cents": ...}` entry per group still holding that payment's
cash. A missing operation record returns `404` as `{"error":{"code":"operation_not_found"}}`; a
record that is not an applied cash payment returns `422` as
`{"error":{"code":"payment_not_reconcilable"}}`.

## Read the daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

Before reporting has started, or for a date before `starts_on`, returns `404` as
`{"error":{"code":"report_not_available"}}`. A missing or invalid date returns `422` as
`{"error":{"code":"invalid_reporting_date"}}`.

A successful response is `{"data": <report>}`. The report contains `date`, `status: "open"`, a
`cash` array ordered by `property_id`, and one company-wide `credit` object. A property is omitted
from `cash` only when its opening balance, closing balance, and every movement are zero. Each cash
entry has this shape:

```json
{
  "property_id": "ams-canal",
  "opening_held_cents": 1000,
  "movements": {
    "received_cents": 500,
    "transferred_in_cents": 0,
    "transferred_out_cents": 0,
    "refunded_cents": 0,
    "retained_cents": 0,
    "converted_to_credit_cents": 0,
    "reduced_cents": 0,
    "charged_back_cents": 0
  },
  "closing_held_cents": 1500
}
```

and the credit object has this shape:

```json
{
  "opening_liability_cents": 0,
  "movements": {
    "issued_cents": 0,
    "expired_cents": 0,
    "consumed_cents": 0,
    "revoked_cents": 0,
    "absorbed_cents": 0
  },
  "closing_liability_cents": 0
}
```

For an operation processed after reporting starts, its posting date is the later of its
`occurred_on` and `starts_on`; all of its finance effects use the same posting date.

- cash closing = opening + received + transferred in − transferred out − refunded − retained
  − converted to credit − reduced − charged back;
- credit closing = opening + issued − expired − consumed − revoked − absorbed.

Across all properties on a date, transferred-in and transferred-out amounts are equal. Credit that
remains unused through its `expires_on` date expires on the following date and is reported even
when no partner operation was submitted that day.
