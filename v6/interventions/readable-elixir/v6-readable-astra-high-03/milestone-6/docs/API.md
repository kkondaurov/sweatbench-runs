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
    "cash_retained_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to either refunded or retained. Unpaid deposit requirements are not cash and never appear in these
totals.

## Start finance reporting

Submit `start_finance_reporting` through the partner batch endpoint:

```json
{
  "operation_id": "finance-start-1",
  "type": "start_finance_reporting",
  "occurred_on": "2026-10-04",
  "starts_on": "2026-10-04"
}
```

The applied result contains exactly `operation_id`, `status: "applied"`, and `starts_on`.
This operation addresses no group and ignores revision guards. Missing or invalid `starts_on`
returns `invalid_reporting_date`; a subsequent start with a different operation identifier returns
`reporting_already_started`. Durable retry and conflict rules apply.

The opening position captures all financial state committed before inception, including earlier
operations in the same batch, regardless of their occurrence dates. Subsequent operations post on
the later of `occurred_on` and `starts_on`.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

A missing or invalid date returns `422` with `invalid_reporting_date`. Before inception, or for a
date earlier than `starts_on`, the endpoint returns `404` with `report_not_available`.

The response is `{"data": <report>}` with `date`, `status: "open"`, `cash`, and `credit`.
Cash entries are ordered by `property_id` and contain:

- `property_id`, `opening_held_cents`, and `closing_held_cents`;
- `movements` with `received_cents`, `transferred_in_cents`, `transferred_out_cents`,
  `refunded_cents`, `retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and
  `charged_back_cents`.

The company-wide `credit` object contains `opening_liability_cents`, `closing_liability_cents`,
and `movements` with `issued_cents`, `expired_cents`, `consumed_cents`, `revoked_cents`, and
`absorbed_cents`. All movement fields are present, including zeros. Properties are omitted only
when both balances and every movement are zero.

Movements are signed net amounts. Cash receipts and incoming transfers increase held cash; the
other cash classifications decrease it. Credit issuance increases liability; the other credit
classifications decrease it. A chargeback of settled cash reverses the original settlement
classification at the settlement property and adds charged-back cash there. Transfers and later
corrections follow the properties that actually hold or settled the funding.

Unused credit expires on the day after `expires_on`, including days without partner operations.
Applied credit pauses expiry. Reports are read-only and may change when later submissions post to
an earlier date. Unlike the ledger's `on` parameter, the report date selects posted history, so
future-posted operations are excluded from that day's closing position.
