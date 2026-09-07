# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

The cancellation-economics migration backfills policy versions from each group's original
`booked_on` and rate plan, preserving existing prices, revisions, and cash settlements. It also
adds credit lots and their group applications. Run `mix ecto.migrate` against the existing database
before starting this release.

Credit expiry is evaluated when reading balances or applying credit; it needs no scheduled job.
Use `?on=YYYY-MM-DD` on ledger and guest-credit reads for a reproducible expiry date. These reads
filter current balances and do not replay the operation history.
