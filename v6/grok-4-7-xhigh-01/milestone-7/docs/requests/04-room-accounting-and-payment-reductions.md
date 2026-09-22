# Add room accounting and payment reductions

Group organizers often reduce their room block without cancelling the entire reservation. Finance
also receives corrections when a payment provider reports that previously recorded cash was
overstated or partially reduced. Support both workflows while preserving the operation durability
introduced in the previous release.

## Room-level accounting

Expose the room-level lodging and deposit amounts already used to calculate the group requirement.
Group totals are sums of the active rooms.

Cash and credit fund active room deposits in the rooms' original order, filling one room's deposit
before moving to the next. New funding operations allocate in operation-processing order.

When this release is deployed, some active groups can contain funding from before durable operation
records existed. Bring that funding forward as one unattributed senior block per group: allocate its
aggregate cash first, then its hotel-credit lots in original consumption order. Allocate this block
before funding represented by durable operation records. Recorded funding means applied cash
payments and hotel-credit applications. Classify it by the retained operation type and allocate it
afterward in durable-record commit order, regardless of `occurred_on`. Do not change any aggregate
cash, credit, or liability balance while creating room allocations.

Group responses now expose these fields on every room:

- `status` (`active` or `cancelled`);
- `deposit_due_cents`;
- `cash_paid_cents`;
- `credit_paid_cents`.

The group's lodging, due, paid, and outstanding totals describe active rooms only.

## Settling selected rooms

Add a `cancel_rooms` operation with `group_id`, `room_ids`, and the same optional `refund_method`
used by full cancellation.

All supplied room identifiers must identify distinct, active rooms in the group. Otherwise reject
the complete operation with `invalid_rooms`.

For selected rooms, settle their allocated cash and credit using the same date, policy, refund
method, bonus, and restoration rules as full cancellation. Unpaid deposit for those rooms ceases to
be due. Other rooms and their allocations are unchanged.

Compute a hotel-credit bonus once on the selected rooms' combined cash amount, not separately per
room. The result contains `group_id`, `cancelled_room_ids`, `refunded_cents`, `retained_cents`,
`credit_issued_cents`, and `revision`.

Return `cancelled_room_ids` in the group's original room order, regardless of the order supplied by
the caller.

If no active rooms remain, the group becomes `cancelled`. `cancel_group` now settles only the
remaining active rooms and otherwise follows its existing contract.

## Reducing recorded cash

Add a `reduce_cash_payment` operation with `payment_operation_id`, `amount_cents`, and optional
`expected_revision`. It records a provider correction against one cash payment that has a durably
stored, applied result. The addressed group is the original payment's group for revision checking.

Only cash from that specific payment that is still held on active rooms can be reduced. Cash already
refunded, retained, or converted to hotel credit is settled history and never moves through this
operation. Remove held allocations belonging to the target payment in reverse fill order. The
group's outstanding deposit reopens by the amount removed.

Successive reductions compose against the target payment's remaining held cash. An amount equal to
the complete remaining held portion is valid.

Use these rejection codes:

- `operation_not_found` when no durable operation record exists for `payment_operation_id`;
- `payment_not_reducible` when the stored target can never accept a positive reduction, including a
  non-payment operation, a rejected payment, or an applied payment with no held cash remaining;
- `invalid_amount` for a non-positive reduction;
- `reduction_exceeds_held_cash` when a smaller positive amount could succeed but the requested
  amount exceeds the target payment's currently held cash.

Because legacy funding has no durable operation identity, it cannot be targeted and therefore
returns `operation_not_found`.

The applied result contains `payment_operation_id`, the derived `group_id`, `amount_cents`,
`outstanding_deposit_cents`, and `revision`. Add cumulative `cash_reduced_cents` to the ledger. Recorded cash now
equals held cash plus refunded, retained, converted, and reduced cash.

Never rewrite the target payment's stored result. Retrying that original payment continues to
return its exact original result without reapplying cash, even when current group state now differs.
The durable idempotency rules also apply to `cancel_rooms` and `reduce_cash_payment` themselves.

## Charging back a payment

Add a `charge_back_payment` operation with `payment_operation_id` and optional
`expected_revision`. It reverses all cash from one durably recorded payment except any portion
already recorded as reduced. The addressed group is the original payment's group.

Use `operation_not_found` only when no durable record exists for `payment_operation_id`. Use
`payment_not_chargeable` when the record exists but is not an applied cash payment, the payment has
been fully reduced, or that payment was already charged back. A payment can be charged back whether
its group is active or cancelled.

Reclassify every remaining disposition of that payment:

- Remove held allocations in reverse fill order, reopening the active rooms' outstanding deposit.
- Move refunded and retained portions to charged-back cash. The ledger classification changes, but
  the historical refund to the guest or retention by the hotel is not reversed or reissued.
- Move converted principal to charged-back cash and revoke the credit entitlement it created.

When cash from several payments was converted into one hotel-credit lot, assign entitlement in the
funding order used by room accounting, with the unattributed senior block first. For each payment,
its entitlement is the standard 10%-bonus value of settled cash through that payment minus the
bonus value through the preceding payment. Apply the standard half-up rounding to both running
totals. The entitlements telescope exactly to the issued lot and are calculated independently for
each lot to which a payment contributed.

Credit within a lot remains fungible; spending is never attributed back to individual payments. A
clawback removes the payment's entitlement from the lot's remaining balance first. Any entitlement
that cannot be removed becomes that lot's unrecovered clawback. A lot's current shortfall is the
lesser of its unrecovered clawback and credit from that lot still applied to active groups.
`credit_shortfall_cents` is the sum of those current lot shortfalls.

If credit later returns to a shortfalled lot, extinguish unrecovered clawback before making any
amount available. This absorption occurs before checking the lot's expiry; only an excess then
becomes available or expires under the existing rules. Non-refundable settlement of credit reduces
the shortfall automatically because that credit is no longer applied to an active group.

`credit_liability_cents` continues to include credit applied to active groups, including credit
covered by a current shortfall. Liability decreases when unspent entitlement is revoked, applied
credit is consumed by non-refundable settlement, credit expires, or a restoration is absorbed by
shortfall.

The applied result contains `payment_operation_id`, the derived `group_id`,
`charged_back_cents`, `outstanding_deposit_cents`, and `revision`. Add cumulative
`cash_charged_back_cents` and current `credit_shortfall_cents` to the ledger. Recorded cash now
equals held, refunded, retained, converted, reduced, and charged-back cash.

A chargeback increments only the original payment group's revision, exactly once. It does not
change the state or revision of groups funded by the affected credit. Never rewrite the original
payment's stored result. Chargebacks are durably idempotent under the existing rules.

## Reconciling one payment

Add `GET /api/v1/payments/:payment_operation_id`. For a durably recorded, applied cash payment,
return:

```json
{
  "data": {
    "payment_operation_id": "pay-17",
    "original_group_id": "group-81",
    "recorded_cents": 5000,
    "held_cents": 1000,
    "refunded_cents": 500,
    "retained_cents": 500,
    "converted_to_credit_cents": 1000,
    "reduced_cents": 500,
    "charged_back_cents": 1500
  }
}
```

Every amount is the current disposition of cash from that payment. The response contains exactly
the fields shown above. All seven monetary fields are always present, including when zero. The six
disposition fields sum exactly to `recorded_cents`. They must agree with the group, room, and ledger
views; reading a statement never changes state.

Return `404` as `{"error":{"code":"operation_not_found"}}` when no durable operation record
exists. Return `422` as `{"error":{"code":"payment_not_reconcilable"}}` when the record exists
but is not an applied cash payment. Funding from before durable operation records has no payment
identifier and therefore cannot be read through this endpoint.
