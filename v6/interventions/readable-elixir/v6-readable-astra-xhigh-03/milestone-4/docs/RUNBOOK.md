# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.


## Room accounting upgrade

Run `mix ecto.migrate` before serving this release. The migration adds room allocations, payment
cash dispositions, and credit entitlements; it also permits several cancellation credit lots per
group. Existing funding is allocated without altering aggregate cash, credit, liability, or group
revisions. Existing operation submissions and results are retained verbatim.

Funding without a durable journal record becomes an unattributed senior block: cash first, then
credit lots in original consumption order. Applied cash payments and credit applications retained
in the journal follow in first-commit order, regardless of partner dates. Unattributed cash cannot
be reduced, charged back, or read as an identified payment.

Use `/api/v1/payments/:payment_operation_id` to reconcile a durable payment's current dispositions.
Use `/api/v1/operations/:operation_id` to inspect its original outcome; that result does not change
after cancellation, reduction, or chargeback. Ledger reads now include cumulative reductions and
chargebacks as well as current credit shortfall. A shortfall does not remove credit already applied
to another reservation or advance that reservation's revision.

The migration refuses rollback after a room cancellation, reduction, or chargeback has been
applied: the earlier schema cannot represent those facts. Recovery to an earlier release requires an appropriate database backup; an older application
version cannot safely process the new accounting state.
