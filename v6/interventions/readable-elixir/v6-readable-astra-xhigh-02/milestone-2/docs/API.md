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
- `cash_paid_cents`
- `credit_paid_cents`
- `outstanding_deposit_cents`

The total paid is cash plus hotel credit. Paid amounts remain historical after cancellation,
while the deposit due and outstanding amounts become zero.

Groups also include `policy_version` and `refundable_until`. Flexible bookings before `2027-01-01`
use `flex-14`; bookings on or after that date use `flex-30`. The refund deadline is arrival minus
14 or 30 days, inclusive. Advance-purchase groups use `advance-nonrefundable` with a `null` deadline.
Rescheduling preserves the policy and returns both fields with the shifted stay dates.

Each room contains `room_id` and `nightly_rate_cents`. A missing group returns
`404` as `{"error":{"code":"group_not_found"}}`.

## Cancel and apply hotel credit

`cancel_group` accepts `refund_method: "cash"` (the default) or `"hotel_credit"`.
Other values, including `null`, are rejected with `invalid_operation`. Hotel credit is only
available for refundable cancellations; otherwise the operation is rejected with
`refund_method_not_available` and the group stays active.

A refundable hotel-credit cancellation converts its cash funding into a credit lot with a 10%
bonus, rounded to the nearest cent with halves upward. The cancellation result adds
`credit_issued_cents`; `refunded_cents` and `retained_cents` are both zero for converted cash.
No lot is created when there is no cash to convert. Lots remain available through cancellation
plus 365 calendar days.

`apply_hotel_credit` supplies `group_id` and a positive integer `amount_cents`. It uses the group's
guest credit, ordered by expiry and then `source_operation_id`, evaluating expiry on the operation's
`occurred_on` date. It shares the cash payment validation errors and returns `insufficient_credit`
when available credit is too small. Its result contains `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`.

Credit applied to an active group has its expiry paused. Refundable cancellation restores that
credit to its original lots without another bonus; amounts whose original expiry has passed expire
immediately. Non-refundable cancellation consumes applied credit and retains only the cash portion.
Revision checks precede refund-method and credit-availability validation.

## Read guest credit

`GET /api/v1/guests/:guest_id/credit?on=2028-05-02`

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

Expired and exhausted lots are omitted. Lots are ordered by `expires_on`, then
`source_operation_id`. Guests without available credit return zero and an empty lots array.

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
    "credit_liability_cents": 0
  }
}
```

`cash_held_cents` is cash currently applied to active reservations. Cancellation moves that cash
to refunded, retained, or converted-to-credit totals. Conversion records the original cash amount;
the credit liability includes the bonus. Liability includes both available credit and credit
applied to active groups. Expiry and non-refundable consumption reduce liability. Unpaid deposit
requirements never appear in these totals.

The ledger and guest-credit endpoints accept an optional `on=YYYY-MM-DD`, defaulting to the current
UTC date. This filters expiry against current persisted balances; it is not a historical replay
of operations. Reads do not mutate balances. An invalid date returns `422` as
`{"error":{"code":"invalid_date"}}`.
