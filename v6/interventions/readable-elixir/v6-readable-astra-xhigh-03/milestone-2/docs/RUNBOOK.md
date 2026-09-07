# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills every existing group's policy from its original
booking date and rate plan, including rescheduled and cancelled groups. Existing cash balances,
accounting entries, and revisions are preserved. Run `mix ecto.migrate` before starting the new
version against an existing database.

Credit expiry needs no scheduled job: reads and redemption evaluate the stored expiry date.
Use `?on=YYYY-MM-DD` on ledger and guest-credit reads to inspect expiry against a chosen date.
These reads use current balances and do not reconstruct historical accounting. Credit held by an
active reservation remains a liability after its lot expires, until that reservation is settled.
