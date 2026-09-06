# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills existing groups in the migration transaction. It preserves
funding balances and audit records, allocating unattributed cash and credit before durable funding
in commit order. Previously cancelled groups expose zero active-room totals while retaining their
cash settlement history. Run migrations before serving requests with the new release.

Room accounts persist funding order, cash dispositions, and conversion entitlements. Lot clawbacks
persist unrecovered credit revocations. These records commit with group updates and operation audit
results; include the entire SQLite database in backups and restores.
