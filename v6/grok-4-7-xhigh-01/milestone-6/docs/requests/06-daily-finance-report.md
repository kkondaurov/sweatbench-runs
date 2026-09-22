# Add the daily finance report

Northstar's controllers reconcile GroupStay with each property's management system every morning.
Give them a durable reporting inception point and a daily report that explains how held cash and
hotel-credit liability moved.

## Starting finance reporting

Add a `start_finance_reporting` partner operation with `starts_on` as an ISO 8601 date. It does not
address a group and has no revision guard.

The first applied start operation enables reporting. The financial state immediately before that
operation is processed becomes the opening position on `starts_on`. This includes every operation
already committed, even one whose `occurred_on` is on or after `starts_on`. In the same batch,
operations before the start contribute to the opening position and operations after it contribute
movements.

The applied result contains exactly `operation_id`, `status`, and `starts_on`. Once reporting has started, a
different start operation is rejected with `reporting_already_started`. A retry of the original
operation follows the existing durable replay and conflict rules.

Reject an invalid or missing `starts_on` as `invalid_reporting_date`.

## Reading one day

Add `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`. A missing or invalid date returns `422` as
`{"error":{"code":"invalid_reporting_date"}}`. Before reporting has started, or for a date before
`starts_on`, return `404` as `{"error":{"code":"report_not_available"}}`.

A successful response is `{"data": <report>}`. The report contains `date`, `status: "open"`, a
`cash` array ordered by `property_id`, and one company-wide `credit` object. Omit a property from
`cash` only when its opening balance, closing balance, and every movement are zero.

Each cash entry has exactly this shape:

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

The credit object has exactly this shape:

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

Movement amounts are signed net amounts within their named classification. A normal refund reports
positive `refunded_cents`; reversing an earlier refund reports negative `refunded_cents` together
with positive `charged_back_cents`. For every property:

```text
closing held = opening held
             + received + transferred in - transferred out
             - refunded - retained - converted to credit - reduced - charged back
```

Across all properties on a date, transferred-in and transferred-out amounts are equal. Transfers
use the source and destination groups' properties. A later correction follows the affected cash to
the property where it is held or where it was settled; it is not forced back to the payment's
original property.

Credit movements are positive when liability leaves through expiry, consumption, revocation, or
shortfall absorption, and positive when issued liability enters. Therefore:

```text
closing liability = opening liability + issued - expired - consumed - revoked - absorbed
```

Applying or restoring hotel credit does not itself change liability and has no movement column.
Credit that remains unused through its `expires_on` date expires on the following date. The report
must show that expiry even when no partner operation was submitted that day.

## Posting dates

For an operation processed after reporting starts, its reporting posting date is the later of its
`occurred_on` and `starts_on`. All finance effects of that operation use the same posting date.
Later submissions can therefore change an earlier open report.

Report movements must reconcile to the existing current views. Reading reports in any order, or
reading one repeatedly, never changes a report or any domain state. Equivalent batches and
sequential submissions produce equivalent reports.

Rejected operations leave no reporting movement. A durable retry returns its stored result and
does not report a movement twice. If a later operation in a batch is rejected, movements from
earlier applied operations remain.
