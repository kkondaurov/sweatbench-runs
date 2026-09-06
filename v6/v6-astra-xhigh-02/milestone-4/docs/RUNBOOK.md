# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The room-accounting migration backfills allocations without changing cash, credit, liability,
revisions, or durable operation records. For each group it allocates legacy cash first, then legacy
credit in original consumption order, followed by recorded funding in durable commit order.
It also reconstructs settled payment dispositions and credit entitlements for recorded payments.
Run `mix ecto.migrate` before starting the upgraded service; allocation creation is part of the
migration transaction, not a side effect of reads.
