# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Room-accounting upgrade

Run `mix ecto.migrate` before serving the new code. The room-accounting migration prices existing
rooms, imports historical cash dispositions, and creates held allocations without changing cash,
credit-lot, or liability balances. Cancelled groups now expose zero active-room totals. Existing
operation submissions, results, and revisions remain unchanged.

For each group, unattributed funding is allocated first: aggregate cash, then hotel-credit lots in
original consumption order. Applied funding retained in the operations table follows in commit
order, using the retained operation type rather than its date or the shared payment-result shape.
The migration uses its own schema-independent backfill so future application changes do not alter
how older databases are upgraded.

Cash accounts retain current dispositions separately from immutable operation receipts. Room
allocations track only currently held funding. Credit entitlements record each payment's share of
each issued lot; credit spending within a lot stays fungible. Use the payment endpoint for current
reconciliation and the operation endpoint for the original receipt.

Room settlements and provider corrections cannot be represented by the earlier schema. After
accepting these operations, use a forward migration for repairs instead of downgrading the service.
