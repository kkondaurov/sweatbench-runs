# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills allocations without replaying partner operations. Legacy
funding is senior (cash first, then credit lots in consumption order); audited funding follows in
first-commit order. Existing payment results and audit records remain unchanged. The migration also
retains settled payment provenance and computes entitlements for existing conversion lots, so those
payments can be reconciled or charged back after upgrade.

Cash allocation rows are the source of current cash dispositions. Group paid totals cache active
funding only. Credit allocation rows represent paused-expiry liability; lot clawbacks track revoked
entitlement awaiting absorption. These records and the operation result commit together.
