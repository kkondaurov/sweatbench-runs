# Launch the group-deposit service

Northstar is onboarding its first property-management-system gateway. Implement the partner batch
endpoint and the read endpoints in the API document. The service must support opening, funding,
moving, and cancelling group reservations.

## Opening a group

An `open_group` operation supplies the fields shown in the API example.

- A stay has at least one night and one room. Room identifiers are unique within the group.
- Each room's lodging amount is the number of nights multiplied by its nightly rate. The group
  lodging total is the sum of those room amounts.
- A flexible room requires a 20% deposit. Calculate and round each room's deposit separately, then
  sum the room deposits for the group.
- An `advance_purchase` room requires its full lodging amount as the deposit.
- Percentage calculations round to the nearest cent; an exact half-cent rounds upward.
- Group identifiers are unique.

The applied result contains `group_id`, `deposit_due_cents`, and `revision`. Domain validation failures are
rejected without creating a group. Use `group_already_exists`, `invalid_stay`, `invalid_rooms`, or
`invalid_rate_plan` as appropriate.

The operation's `occurred_on` date is the group's `booked_on` date.

## Recording cash

A `record_cash_payment` operation contains `group_id` and `amount_cents` in addition to the common
operation fields. It applies cash to an active group's outstanding deposit.

Reject a payment when the group is missing, no longer active, the amount is not usable as a
payment, or it exceeds the outstanding deposit. Use `group_not_found`, `group_not_active`,
`invalid_amount`, and `payment_exceeds_outstanding` respectively.

The applied result contains `group_id`, `amount_cents`, `outstanding_deposit_cents`, and `revision`.

## Rescheduling

A `reschedule_group` operation contains `group_id` and `new_arrival_on`.

The departure date shifts by the same number of calendar days, so the length and price of the stay
do not change. The new arrival must be after the operation date. Only active groups can be moved.

The applied result contains `group_id`, `new_arrival_on`, `new_departure_on`, and `revision`. Reject unusable
dates with `invalid_stay`; use the existing group errors for missing or inactive groups.

## Cancelling a group

A `cancel_group` operation contains `group_id`.

- Flexible reservations are refundable when cancellation occurs at least 14 calendar days before
  arrival. Cash already paid is refunded.
- Flexible reservations cancelled later are non-refundable. Cash already paid is retained.
- Advance-purchase reservations are always non-refundable.
- Unpaid deposit is simply no longer due.

The applied result contains `group_id`, `refunded_cents`, `retained_cents`, and `revision`. The group becomes
`cancelled`; a later payment, reschedule, or cancellation is rejected with `group_not_active`.

## Concurrent updates

Follow the revision contract in the API document for payments, reschedules, and cancellations.
Opening a group creates revision `1`; `expected_revision` is not used by `open_group`. Every later
applied operation addressed to a group increments it exactly once, even when the operation does not
change the group's visible booking fields. Rejections never increment it.

Resolve group existence before comparing revisions. For an existing group, reject a stale revision
before evaluating the operation's other domain rules. The stale rejection must contain the fields
shown in the API document and leave the group and ledger unchanged.

## Batch failures

Unknown operation types or operations missing data needed to identify and apply them are rejected
with `invalid_operation`. Every rejection must leave the database exactly as it was before that
operation began, and processing must continue with the next operation.
