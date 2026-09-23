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

## Finance reporting

Start reporting with a `start_finance_reporting` operation containing `starts_on`. The financial
state immediately before that operation is the opening position, including operations already
committed with later `occurred_on` dates. The applied result contains exactly `operation_id`,
`status`, and `starts_on`. A second distinct start operation is rejected with
`reporting_already_started`; an invalid or missing date is rejected with
`invalid_reporting_date`.

Close reporting through a date with a `close_finance_period` operation containing
`period_end_on`. The date must be on or after `starts_on` and strictly later than the latest
successful close. A close before reporting starts, a missing or invalid date, or a repeated or
earlier cutoff is rejected with `invalid_period`. The applied result contains exactly
`operation_id`, `status`, and `period_end_on`.

```json
{
  "operation_id": "close-2026-10",
  "type": "close_finance_period",
  "period_end_on": "2026-10-31"
}
```

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns `{"data": <report>}`. A missing or
invalid date returns `422` with `invalid_reporting_date`; a date before reporting starts, or a
request made before reporting starts, returns `404` with `report_not_available`. Reports through
the latest close have `status: "closed"`; later reports have `status: "open"`.

Each report contains `date`, `status`, `cash`, `credit`, and `late_adjustments`. Cash entries are
ordered by `property_id` and contain `opening_held_cents`, the signed cash movement classifications,
and `closing_held_cents`. The credit object contains opening liability, the `issued_cents`,
`expired_cents`, `consumed_cents`, `revoked_cents`, and `absorbed_cents` movements, and closing
liability. The `late_adjustments` object contains the same cash classifications grouped by
property and the same credit classifications. Its movements are added to the ordinary movements
to calculate closing balances. It reports effects shifted forward because a close had already
committed. Reading a report does not change finance state.

After a close, an operation whose `occurred_on` falls on or before the closed cutoff posts its
finance effects on the first open day. An operation dated after the cutoff keeps its date. Its
posting date is fixed when it commits, so a later close does not move it.
