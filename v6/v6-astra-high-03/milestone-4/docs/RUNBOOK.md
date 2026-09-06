# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting upgrade adds cash dispositions, room allocations, and credit entitlements.
Run `mix ecto.migrate` before starting the upgraded service. The migration allocates legacy active
funding as one senior block (cash first, then credit in consumption order), followed by applied
funding classified by retained operation type in durable commit order. It preserves aggregate
cash and credit balances, group revisions, and existing durable results. Historical applied cash
payments also receive reconciliation dispositions and converted-credit entitlements.

After partial settlements, reductions, or chargebacks have been recorded, restore a pre-upgrade
database backup to return to an older release: older code cannot represent the new accounting.
