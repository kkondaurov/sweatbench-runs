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

Run `mix ecto.migrate` before serving the new release. The reporting migration adds an empty
inception table and a journal without changing existing balances. Reporting becomes available only
after the first successful `start_finance_reporting` partner operation. Choose its `starts_on`
date and position in the submission stream deliberately: all preceding commits become its opening
position, including operations with later `occurred_on` dates.

Inception, journal entries, domain changes, and durable operation results use the same SQLite
transaction. Keep the database intact across restarts; no reporting process state needs recovery.
Credit expiry is represented by dated journal entries and adjustments, so no scheduler or daily
maintenance job is required. Reading reports never writes to the database.
The migration refuses a downgrade after reporting starts, because dropping inception while keeping
the start operation's durable result would prevent a retry from restoring reporting history.

Daily reports remain open and may change when backdated operations arrive. The ledger's `on`
parameter evaluates expiry on current balances; the daily report instead reconstructs postings
since inception. Reconcile a report's closing balances to the ledger using a date on or after all
submitted posting dates, and the same date for credit expiry.
