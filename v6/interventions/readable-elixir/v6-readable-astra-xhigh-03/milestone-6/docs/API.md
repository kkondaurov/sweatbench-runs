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
  "occurred_on": "2026-11-01",
  "starts_on": "2026-11-01"
}
```

The first applied start captures current held cash by property and company credit liability as
the opening position on `starts_on`. Every operation committed before start contributes to that
opening, regardless of its `occurred_on`. This operation addresses no group and ignores revision
guards. Its result contains exactly `operation_id`, `status: "applied"`, and `starts_on`.

A missing or invalid `starts_on` is rejected with `invalid_reporting_date`. A different start after
reporting is enabled is rejected with `reporting_already_started`. Durable retry and operation
identifier conflict rules apply normally.

## Read a daily finance report

`GET /api/v1/finance/daily-report?date=YYYY-MM-DD`

The required date must be a valid ISO 8601 calendar date; otherwise return `422` with error code
`invalid_reporting_date`. Before reporting starts, or for dates before `starts_on`, return `404`
with error code `report_not_available`.

The response is `{"data": <report>}`. The report contains exactly `date`, `status: "open"`, a
`cash` array, and a company-wide `credit` object. Each cash entry contains `property_id`,
`opening_held_cents`, `movements`, and `closing_held_cents`. The credit object contains
`opening_liability_cents`, `movements`, and `closing_liability_cents`.

All movement columns are always present, including zero amounts:

| Cash movements | Credit movements |
| --- | --- |
| `received_cents` | `issued_cents` |
| `transferred_in_cents` | `expired_cents` |
| `transferred_out_cents` | `consumed_cents` |
| `refunded_cents` | `revoked_cents` |
| `retained_cents` | `absorbed_cents` |
| `converted_to_credit_cents` | |
| `reduced_cents` | |
| `charged_back_cents` | |

Cash entries are ordered by `property_id`; a property is omitted only if its opening, closing,
and every movement are zero. Corrections follow the property holding or settling the affected
cash, including after transfers. Movement amounts are signed: reclassifying a prior refund
reports negative `refunded_cents` and positive `charged_back_cents`.

Cash closing equals opening plus received and transferred in, minus transferred out, refunded,
retained, converted, reduced, and charged back. Credit closing equals opening plus issued, minus
expired, consumed, revoked, and absorbed. Transfers balance across properties. Applied credit
keeps expiry paused; unused credit expires the day after `expires_on`, even without operations.

After inception, operations post on the later of `occurred_on` and `starts_on`. Late submissions
can amend earlier open reports. Rejections and retries add no movements. Report reads are pure
historical projections; the ledger's optional `on` parameter continues to evaluate expiry of
current balances rather than selecting historical operations.
