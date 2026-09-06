# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Finance reporting

Run `mix ecto.migrate` before starting the upgraded service. The finance migration adds opening
balances and a reporting journal without changing existing reservation or payment balances.
Reporting remains disabled until a partner submits `start_finance_reporting` with `starts_on`.
Choose its place in the batch deliberately: prior operations form the opening position, and later
operations post movements. The start is permanent and uses the usual durable operation retry rules.

Opening balances, reporting entries, domain changes, and operation results commit in the same
SQLite transaction. Keep the reporting tables with the rest of the database when backing up or
restoring the service. No scheduled expiry job is needed: signed expiry entries account for unused
credit, redemption, restoration, and revocation. Daily reads aggregate these entries without writes.
Reports remain open and may change after a backdated operation; callers can read them again to
reconcile newly submitted activity.
