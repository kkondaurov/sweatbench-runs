# GroupStay

Northstar Hotels operates twelve city hotels. Corporate travel desks and event agencies often
reserve several rooms under one group and pay a deposit before arrival. Northstar's property
management systems still own room inventory and final folio billing, but they do not provide a
consistent view of group deposits across properties.

GroupStay is the internal API that fills that gap. A partner gateway sends reservation and payment
operations to GroupStay. GroupStay applies those operations in order, reports the outcome of each
one, and keeps the deposit records needed by support and finance.

## What GroupStay owns

- the rooms represented by each group reservation;
- the deposit required for those rooms;
- cash and hotel credit applied to that deposit;
- cancellation settlements and the resulting finance totals;
- the outcomes returned for partner operations.

Flexible cancellation terms are fixed by booking date: groups booked before 2027-01-01 have a
14-day window, and later bookings have a 30-day window. Refundable guests may take hotel credit
worth 110% of their cash payment. Credit expires 365 days after cancellation, can fund a later
active group's deposit, and returns to its original expiry when that later group is cancelled
while refundable.

## What remains elsewhere

- room availability and room assignment;
- guest authentication and partner authorization;
- charging cards or sending bank refunds;
- taxes, the final hotel folio, and post-stay adjustments.

When GroupStay records a payment or refund, it records the accounting fact reported to it. Payment
providers perform the actual movement of money.
