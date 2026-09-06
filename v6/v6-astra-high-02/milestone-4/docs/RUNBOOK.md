# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.


Room accounting is introduced by migration `20260905000003_add_room_accounting`. Run `mix ecto.migrate`
before serving requests with this release. It preserves aggregate cash, credit, liability, revisions,
and durable operation records while adding room metadata and payment provenance. Legacy funding is
allocated first (cash, then credit in original consumption order), followed by applied funding in
durable commit order. Cancelled groups retain settlement history and expose zero active lodging.

`room_allocations` retains cash dispositions and active credit provenance; `credit_allocations`
remains the lot-level projection used for liability. `credit_entitlements` records the bonus-inclusive
entitlement created by each payment per lot, and `credit_clawbacks` tracks unrecovered revocations.
Operation results and all accounting changes commit together under the existing SQLite write lock.
Do not reconstruct payment statements from the immutable original payment result alone.

The migration's down direction removes the new accounting tables; it does not undo settlements.
Rolling back after processing new operations requires restoring a consistent database backup.
