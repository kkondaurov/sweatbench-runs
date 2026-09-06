# Add deposit transfers

Organizers sometimes replace one group reservation with another or split an event across two
properties after deposits have already been applied. Let a partner move part of the applied deposit
between two active groups belonging to the same guest without moving money through a provider.

## Moving held funding

Add a `transfer_deposit` operation with:

- `source_group_id`;
- `destination_group_id`;
- `amount_cents`;
- optional `expected_revision` for the source group;
- optional `destination_expected_revision` for the destination group.

Held funding means cash and hotel credit currently allocated to active rooms. Both groups must
exist, be active, be distinct, and have the same `guest_id`.

Move `amount_cents` from the source's active-room allocations in reverse allocation order (most
recently created allocation first), regardless of funding kind. Fill the destination's active rooms
in their original order, preserving the order in which units were drawn. Each moved allocation keeps
its provenance: cash keeps its payment operation identity and hotel credit keeps its original lot.

A transfer does not settle or revalue anything. It computes no credit bonus, does not resume the
expiry of applied credit, and changes no ledger total. It only changes which active rooms hold the
funding.

Reject the complete operation with:

- `invalid_transfer` when the groups are the same or have different guests;
- `group_not_active` when either group is not active, with that group's `group_id`;
- `invalid_amount` when `amount_cents` is not positive;
- `transfer_exceeds_held_funding` when the source has less held funding than requested;
- `transfer_exceeds_outstanding` when the destination has less outstanding deposit than requested.

Resolve source existence, then destination existence. A missing group returns `group_not_found`
with that `group_id`. After both groups exist, check the source revision and then the destination
revision before the transfer rules above. A destination revision mismatch uses `stale_revision`
with the destination's `group_id`, expected value, and actual value.

The applied result contains `source_group_id`, `destination_group_id`, `amount_cents`,
`source_outstanding_deposit_cents`, `destination_outstanding_deposit_cents`, `source_revision`, and
`destination_revision`.

## Revisions across groups

An applied operation increments the revision of every group whose state it changes, and always the
group it is addressed to. This supersedes the earlier single-group wording for reductions and
chargebacks.

Revision guards remain preconditions only for groups explicitly addressed by the request.
`reduce_cash_payment` and `charge_back_payment` continue to check `expected_revision` against the
original payment group. If either operation changes funding in other groups, those groups still
increment their revisions even though they are not guarded by that request.

The single `revision` in a reduction or chargeback result is the revision of its addressed original
payment group.

## Later settlement and corrections

Transferred cash settles under the destination group's cancellation policy. If it is converted to
hotel credit, the existing bonus rule applies to the cash settled there.

Transferred hotel credit remains applied with expiry paused. Refundable settlement restores it to
its original lot and original expiry without another bonus. Existing expiry and shortfall absorption
rules apply when it returns. Non-refundable settlement consumes it normally.

Reductions and chargebacks follow a payment's allocations wherever they currently fund rooms.
When held allocations from one payment span groups, remove them in reverse allocation order across
all groups. Never rewrite the original payment result.

## Payment statement evolution

Once any funding from a cash payment has participated in a transfer, that payment's statement adds
`held_by_group`, ordered by `group_id`:

```json
"held_by_group": [
  {"group_id": "group-81", "amount_cents": 500},
  {"group_id": "group-92", "amount_cents": 500}
]
```

Omit groups with no held cash from this list. Its amounts sum to `held_cents`; after none remains,
return an empty list. Payments that have never participated in a transfer retain the earlier
statement shape without this field. All earlier statement fields retain their meaning.

Transfers use the durable idempotency and same-batch visibility rules already established for
partner operations. A retry returns the exact stored result without moving funding again.
