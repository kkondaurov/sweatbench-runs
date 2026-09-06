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

Submit a `start_finance_reporting` operation to the partner batch endpoint:

```json
{"operation_id":"finance-start","type":"start_finance_reporting","starts_on":"2026-11-26"}
```

This operation needs no group, `occurred_on`, or revision guard. Its applied result contains exactly
`operation_id`, `status: "applied"`, and `starts_on`. It captures the current held cash by property
and company-wide credit liability as the opening position on that date, including operations
processed earlier in the same batch regardless of their occurrence dates. It can be applied once;
later starts return `reporting_already_started`. Missing or invalid `starts_on` returns
`invalid_reporting_date`. Durable retry and conflict rules apply.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

The response is `{"data": <report>}` with `date`, `status: "open"`, a `cash` array sorted by
`property_id`, and a company-wide `credit` object. Each cash entry contains `property_id`,
`opening_held_cents`, `closing_held_cents`, and `movements` with all of these integer-cent fields:

- `received_cents`, `transferred_in_cents`, `transferred_out_cents`
- `refunded_cents`, `retained_cents`, `converted_to_credit_cents`
- `reduced_cents`, `charged_back_cents`

The credit object contains `opening_liability_cents`, `closing_liability_cents`, and `movements`
with `issued_cents`, `expired_cents`, `consumed_cents`, `revoked_cents`, and `absorbed_cents`.
All movement columns are present, including zeros. Cash entries are omitted only when both balances
and all movements are zero. Movements are signed net amounts; for example, charging back refunded
cash reports a negative refund and a positive chargeback at the property that settled it.

After inception, operation effects post on the later of `occurred_on` and `starts_on`. Late
submissions can change earlier open reports. Unused credit expires the day after `expires_on`,
including days with no submitted operations. Reads never change state.

A missing or invalid `date` returns `422` with `invalid_reporting_date`. Before inception, or for a
date before `starts_on`, return `404` with `report_not_available`, using the usual error envelope.
