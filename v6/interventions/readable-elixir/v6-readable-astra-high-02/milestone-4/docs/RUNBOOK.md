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

Run the Ecto migrations before starting the new application version. The room-accounting
migration creates room funding slices and credit entitlements without changing aggregate
cash, credit, or liability. Existing unattributed cash and credit form the senior funding
block; applied durable funding follows in audit commit order. Audit payloads and original
results are preserved. Cancelled groups retain their original rooms but report zero active
lodging totals.

Room allocations retain payment cash dispositions and credit-lot provenance. Group totals
and the group/lot `credit_allocations` summary are updated in the same operation transaction.
Do not edit these balances independently. Payment statements and the ledger provide the
read-only reconciliation views; corrections belong in partner operations.
