# Add finance period close

Controllers need published daily figures to stop moving after a period is signed off. Add a
durable close operation and keep later corrections visible without rewriting a closed day.

## Closing through a date

Add a `close_finance_period` partner operation with `period_end_on` as an ISO 8601 date. It does not
address a group and has no revision guard.

The close applies only when finance reporting has started, `period_end_on` is on or after
`starts_on`, and it is strictly later than the latest successful close. Otherwise reject it with
`invalid_period`. The applied result contains exactly `operation_id`, `status`, and `period_end_on`.

The operation uses the existing durable replay and conflict rules. Replaying an applied close
returns its exact stored result. A different operation attempting the same or an earlier cutoff is
rejected.

When a close is processed, every finance report through `period_end_on` becomes published and must
remain byte-for-byte stable in its `data` value across later operations, later closes, and process
restarts. Those reports return `status: "closed"`; later reports return `status: "open"`.

## Posting after a close

An operation processed after a close has this reporting posting date:

```text
max(occurred_on, starts_on, day after the latest cutoff at the moment it commits)
```

If `occurred_on` is already in the open period, keep that date. Otherwise post the complete finance
effect on the first open day. An operation keeps the posting date chosen when it commits; a later
close never moves it again.

Operations earlier in the same batch are visible. An operation immediately before a close can post
into the period being closed. An old-dated operation immediately after that close posts on the
first open day.

This rule changes only finance reporting. Group, room, ledger, payment-statement, and stored
operation results retain their existing current-state meanings.

## Identifying late adjustments

Every successful daily report now adds `late_adjustments`:

```json
{
  "cash": [
    {
      "property_id": "ams-canal",
      "movements": {
        "received_cents": 0,
        "transferred_in_cents": 0,
        "transferred_out_cents": 0,
        "refunded_cents": -100,
        "retained_cents": 0,
        "converted_to_credit_cents": 0,
        "reduced_cents": 0,
        "charged_back_cents": 100
      }
    }
  ],
  "credit": {
    "issued_cents": 0,
    "expired_cents": 0,
    "consumed_cents": 0,
    "revoked_cents": 0,
    "absorbed_cents": 0
  }
}
```

The block contains only movements whose posting date was moved forward by a close. Its cash array
is ordered by `property_id` and omits all-zero properties. The credit object is always present.
Ordinary movement columns remain in each cash entry and the credit object's `movements` block.
For each classification, the day's total movement is the ordinary value plus the corresponding
late-adjustment value. Opening and closing balances use both.

Keep the signed classifications even when their net balance effect is zero. For example, charging
back a previously refunded 100 cents can report `refunded_cents: -100` and
`charged_back_cents: 100`; it must not disappear as a zero-net adjustment.

Closing a period does not require a particular storage design, background job, scheduler, or
calendar-month boundary.
