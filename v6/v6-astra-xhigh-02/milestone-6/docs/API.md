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
  "operation_id": "finance-inception",
  "type": "start_finance_reporting",
  "starts_on": "2026-10-04"
}
```

This operation has no group or revision guard. Its applied result contains exactly
`operation_id`, `status: "applied"`, and `starts_on`. Missing or invalid `starts_on` is rejected
with `invalid_reporting_date`. Once started, another start is rejected with
`reporting_already_started`; durable retries and conflicts retain their usual behavior.

The opening position includes all state committed before this operation, including earlier entries
in its batch, regardless of their occurrence dates. Opening credit is valued on `starts_on`:
already expired unused credit is excluded, while credit applied to active rooms remains included.
Subsequent operations post on the later of `occurred_on` and `starts_on`.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

`date` is required. A missing or invalid date returns `422` with error code
`invalid_reporting_date`. Before reporting starts, or for an earlier date, the endpoint returns
`404` with error code `report_not_available`.

The response is `{"data": <report>}`. Reports have `date`, `status: "open"`, a `cash` array
ordered by `property_id`, and one company-wide `credit` object. Each cash entry contains exactly:

- `property_id`, `opening_held_cents`, `closing_held_cents`;
- `movements`, with `received_cents`, `transferred_in_cents`, `transferred_out_cents`,
  `refunded_cents`, `retained_cents`, `converted_to_credit_cents`, `reduced_cents`, and
  `charged_back_cents`.

The credit object contains exactly `opening_liability_cents`, `closing_liability_cents`, and
`movements`, with `issued_cents`, `expired_cents`, `consumed_cents`, `revoked_cents`, and
`absorbed_cents`. All movement fields are always present, including zero values. Cash properties
are omitted only if their opening, closing, and every daily movement are zero.

Movements are signed net amounts. Cash closing equals opening plus received and transferred in,
minus transferred out and every settlement/correction column. Credit closing equals opening plus
issued, minus expired, consumed, revoked, and absorbed. Corrections reverse prior settlement
classifications at the property where the cash was held or settled. Transfers within one property
still report both directions, and only their cash portion appears in cash movements.

Unused credit expires the day after `expires_on`, even without operations that day. Applied credit
has paused expiry. Restoration can reduce liability through expiry or shortfall absorption;
application and ordinary restoration have no separate movement columns. Backdated submissions can
revise an earlier open report, including its expiry totals. Reads never change state, and retries
and rejections add no movements. See [daily finance reporting](requests/06-daily-finance-report.md)
for the complete contract.
