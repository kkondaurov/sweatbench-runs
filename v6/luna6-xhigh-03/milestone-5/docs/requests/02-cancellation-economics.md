# Evolve cancellation economics

Revenue management is changing the cancellation window for new flexible reservations. At the same
time, Northstar wants refundable guests to choose hotel credit instead of a cash refund and use it
for a later reservation.

## Policy versions

- Flexible groups booked before `2027-01-01` retain the 14-day cancellation window.
- Flexible groups booked on or after `2027-01-01` use a 30-day cancellation window.
- Advance-purchase groups remain non-refundable.
- A group's policy version is fixed when the group is opened. Rescheduling it never moves it to a
  newer policy.

Group responses now include `policy_version` (`flex-14`, `flex-30`, or
`advance-nonrefundable`) and `refundable_until`. For a flexible group, `refundable_until` is the
arrival date minus its cancellation window and cancellation on that date is refundable. It is
`null` for advance purchase.

Existing groups created before this release must remain readable and receive the policy that their
original booking date implies.

`reschedule_group` still shifts the departure by the same number of days. Its applied result now
also includes the group's fixed `policy_version` and the recomputed `refundable_until`.

## Issuing credit on cancellation

`cancel_group` accepts an optional `refund_method`, either `cash` or `hotel_credit`. Omitting it
means cash, preserving existing callers.

When a cancellation is refundable and hotel credit is selected, the cash-funded portion becomes a
credit lot worth 110% of that cash. Apply the standard rounding rule to the 10% bonus. The lot is
available through the date 365 days after cancellation and expires the following day. Its
`source_operation_id` is the cancellation operation identifier.

The original cash is neither refunded nor counted as a non-refundable cancellation fee. Move it
from `cash_held_cents` to a new cumulative ledger total,
`cash_converted_to_credit_cents`. For this settlement, both `refunded_cents` and
`retained_cents` are zero.

Hotel credit is not a way around a non-refundable policy. If `hotel_credit` is requested for a
non-refundable cancellation, reject the operation with `refund_method_not_available` and leave the
group active.

The cancellation result adds `credit_issued_cents`.

## Applying credit

Add an `apply_hotel_credit` operation with `group_id` and `amount_cents`.

- The group must be active and the guest must have enough unexpired credit.
- Credit cannot exceed the group's outstanding deposit.
- Consume lots by earliest expiry, then by `source_operation_id` for equal expiries.
- Preserve which lots funded a group so those amounts can be restored if the group is later
  cancelled while refundable.

Applying credit redeems it into the active deposit, so its expiry is paused while it funds that
group. On refundable cancellation, restore it to its original lot and expiry. If that expiry is
already past on the cancellation date, the restored amount expires immediately and reduces the
credit liability instead of becoming available again.

Use `insufficient_credit` when the guest cannot cover the requested amount and the existing payment
validation errors where they apply. The applied result includes `group_id`, `amount_cents`, and
`outstanding_deposit_cents`.

Group responses add `cash_paid_cents` and `credit_paid_cents`.

`apply_hotel_credit` follows the revision contract and its applied result includes `revision`.
Cancellation results continue to include the resulting revision. A rejected refund method or
insufficient-credit attempt does not advance a revision. Revision is checked before those domain
rules when the addressed group exists.

## Settling a group funded by credit

On a refundable cancellation:

- cash with `refund_method: "cash"` is refunded as cash;
- cash with `refund_method: "hotel_credit"` becomes a new credit lot with the 10% bonus;
- previously applied hotel credit returns to its original lots with its original expiry and never
  receives a second bonus.

On a non-refundable cancellation, cash is retained and applied hotel credit is consumed.

## Credit and ledger reads

Add `GET /api/v1/guests/:guest_id/credit` returning:

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

Expired and exhausted lots are omitted. Add `credit_liability_cents` to the ledger. It includes
both available credit and credit currently applied to active groups; applying or restoring credit
therefore does not change the liability unless a restored lot has already expired. Expiry and
non-refundable consumption reduce it.

Return available lots ordered by `expires_on`, then by `source_operation_id`.

Both the guest-credit endpoint and the ledger endpoint accept an optional `on=YYYY-MM-DD` query
parameter and report expiry as of that date. Without it they use the current UTC date. Credit
application always evaluates expiry using the operation's `occurred_on` date.
