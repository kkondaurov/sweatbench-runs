# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills each group's fixed policy from its original
`booked_on` and rate plan, preserving existing cash balances, settlements, revisions, and rooms.
Run `mix ecto.migrate` in the service's environment before starting the updated application.
For a test-environment database, both migration and server commands must use the same
`GROUP_STAY_DATABASE_PATH`.

Credit expiry needs no scheduled sweep. Guest-credit and ledger reads evaluate expiry on the
requested `on` date (or UTC today) without mutating balances; credit application uses the
operation date. Credit allocated to an active group retains its liability past its original
expiry. A refundable cancellation restores allocations only if their original expiry has not
passed on the cancellation date.
