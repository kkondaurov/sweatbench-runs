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

Submit a `start_finance_reporting` operation in a partner batch:

```json
{
  "operations": [
    {
      "operation_id": "op-2001",
      "type": "start_finance_reporting",
      "starts_on": "2027-01-15"
    }
  ]
}
```

The first applied start enables reporting; the financial state immediately before it becomes the
opening position. A different start is rejected with `reporting_already_started`. An invalid or
missing `starts_on` is rejected with `invalid_reporting_date`. The applied result contains exactly
`operation_id`, `status`, and `starts_on`. It addresses no group and has no revision guard.

The posting date for an operation's finance effects is the latest of its `occurred_on`,
`starts_on`, and the day after the latest close cutoff. An operation keeps the posting date chosen
when it commits; a later close never moves it again.

## Close a finance period

Submit a `close_finance_period` operation in a partner batch:

```json
{
  "operations": [
    {
      "operation_id": "op-2002",
      "type": "close_finance_period",
      "period_end_on": "2027-01-31"
    }
  ]
}
```

The close applies only when reporting has started, `period_end_on` is on or after `starts_on`, and
the cutoff is strictly later than the latest successful close. Otherwise it is rejected with
`invalid_period`. The applied result contains exactly `operation_id`, `status`, and
`period_end_on`. It addresses no group and has no revision guard.

When a close is processed, every finance report through `period_end_on` becomes published: the
report's `data` value stays byte-for-byte stable across later operations, later closes, and
process restarts.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

Returns `{"data": <report>}` with `date`, `status` (`"closed"` through the latest close cutoff,
otherwise `"open"`), a `cash` array ordered by `property_id` (each entry has `property_id`,
`opening_held_cents`, the `received` / `transferred_in` / `transferred_out` / `refunded` /
`retained` / `converted_to_credit` / `reduced` / `charged_back` movements, and
`closing_held_cents`), one company-wide `credit` object (`opening_liability_cents`, the `issued` /
`expired` / `consumed` / `revoked` / `absorbed` movements, and `closing_liability_cents`), and a
`late_adjustments` block. A property is omitted from `cash` only when its opening balance, closing
balance, and every movement are zero.

`late_adjustments` holds the day's movements whose posting date was moved forward by a close: a
`cash` array ordered by `property_id` (omitting all-zero properties) with the same movement keys as
an ordinary cash entry, and a `credit` object with the five credit movement keys, always present.
For each classification, the day's total movement is the ordinary value plus the corresponding
late-adjustment value; opening and closing balances use both.

A missing or invalid date returns `422` as `{"error":{"code":"invalid_reporting_date"}}`. Before
reporting starts, or for a date before reporting's start date, the response is `404` as
`{"error":{"code":"report_not_available"}}`.
