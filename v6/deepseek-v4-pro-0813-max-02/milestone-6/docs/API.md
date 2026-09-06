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

## Starting finance reporting

A `start_finance_reporting` operation enables the daily finance report. It carries `starts_on` as
an ISO 8601 date, addresses no group, and has no revision guard:

```json
{
  "operation_id": "fin-1",
  "type": "start_finance_reporting",
  "starts_on": "2026-10-03"
}
```

The first applied start enables reporting. The financial state immediately before it was processed
becomes the opening position on `starts_on`, including every operation already committed. The
applied result contains exactly `operation_id`, `status`, and `starts_on`. Once reporting has
started, a different start operation is rejected with `reporting_already_started`; an invalid or
missing `starts_on` is rejected with `invalid_reporting_date`.

## Reading the daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns the report for one day as
`{"data": <report>}`. A missing or invalid date returns `422` as
`{"error":{"code":"invalid_reporting_date"}}`. Before reporting has started, or for a date before
`starts_on`, the endpoint returns `404` as `{"error":{"code":"report_not_available"}}`.

The report contains `date`, `status` (`open`), a `cash` array ordered by `property_id`, and one
company-wide `credit` object. Properties whose opening balance, closing balance, and every
movement are zero are omitted from `cash`. Each cash entry reports `opening_held_cents`, a
`movements` object of the day's signed net amounts (`received_cents`, `transferred_in_cents`,
`transferred_out_cents`, `refunded_cents`, `retained_cents`, `converted_to_credit_cents`,
`reduced_cents`, and `charged_back_cents`), and `closing_held_cents`, where

```text
closing held = opening held
             + received + transferred in - transferred out
             - refunded - retained - converted to credit - reduced - charged back
```

The credit object reports `opening_liability_cents`, a `movements` object (`issued_cents`,
`expired_cents`, `consumed_cents`, `revoked_cents`, and `absorbed_cents`), and
`closing_liability_cents`, where

```text
closing liability = opening liability + issued - expired - consumed - revoked - absorbed
```

An operation processed after reporting started posts on the later of its `occurred_on` and
`starts_on`; operations without an `occurred_on` post on `starts_on`. Later submissions can
therefore change an earlier open report. Rejected operations leave no movement, and durable
retries do not report a movement twice.
