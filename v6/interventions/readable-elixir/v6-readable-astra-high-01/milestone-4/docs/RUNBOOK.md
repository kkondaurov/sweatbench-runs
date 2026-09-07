# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration reconstructs allocations before the new operation paths are used.
It preserves cash and credit balances and receipt contents: unattributed funding is allocated first,
then recorded funding in durable commit order. It also reconstructs settled cash dispositions and
credit entitlements for recorded payments. Run migrations with the previous application stopped,
then start the new release so writes cannot race the accounting upgrade.
