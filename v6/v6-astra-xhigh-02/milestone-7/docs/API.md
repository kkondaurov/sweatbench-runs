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

## Finance reporting and period close

`start_finance_reporting` accepts `starts_on` and enables daily reporting from the financial
position at that point in operation-processing order. `close_finance_period` accepts
`period_end_on`. Neither operation addresses a group or checks revisions. A close succeeds only
after reporting starts, for a date on or after `starts_on` and strictly later than the latest
successful cutoff. Invalid or missing cutoffs return `invalid_period`.

An applied close returns exactly:

```json
{"operation_id":"close-1","status":"applied","period_end_on":"2026-10-31"}
```

Both operations use the normal durable replay and conflict rules.

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD` returns `{"data": <report>}`. A missing or
invalid date returns `422` with `invalid_reporting_date`; dates before reporting inception return
`404` with `report_not_available`. Reports through the latest cutoff have `status: "closed"` and
remain unchanged across later operations and restarts. Later reports have `status: "open"`.

Every report includes `date`, `status`, cash rows ordered by `property_id`, a company-wide `credit`
object, and `late_adjustments: {"cash": [...], "credit": {...}}`. Late cash rows contain only
`property_id` and `movements`, omitting properties whose classifications are all zero. Late credit
always includes all five credit movement columns. Ordinary and late movement columns are added
together to compute closing balances; signed classifications are preserved even when their net
balance effect is zero.

Financial operations commit their posting date as the latest of `occurred_on`, `starts_on`, and
the day after the current cutoff. Only effects moved forward by a close appear in
`late_adjustments`. Scheduled credit expiry remains on its own date. This changes reporting only;
current group, ledger, and payment-statement views retain their existing meanings.

See the full [daily report](requests/06-daily-finance-report.md) and
[period close](requests/07-period-close.md) contracts for movement columns and reconciliation rules.
