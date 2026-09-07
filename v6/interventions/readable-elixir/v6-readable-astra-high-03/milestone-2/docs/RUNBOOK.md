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
`booked_on` and rate plan, preserving existing deposits, settlements, and revisions. It also adds
credit lots and allocations; those allocations must be retained with the lots in database backups
so refundable cancellations can restore the original funding.

Credit expiry requires no scheduled job. Reads evaluate unallocated balances against the requested
`on` date (UTC today by default), while applied credit remains a liability until settlement.
