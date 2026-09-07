# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Finance reporting inception

Run `mix ecto.migrate` in the service's environment before deploying the reporting code. The finance
migration adds empty reporting tables and preserves existing groups, payments, credit, and audit
records. It does not enable reporting automatically.

Submit one `start_finance_reporting` partner operation with the agreed `starts_on` date. Its opening
position includes all operations committed before it. In a batch, place the start after operations
that belong in the opening position and before operations that should become movements. Retain its
operation identifier for safe retries; reporting inception cannot be replaced by a second start.

Daily reports remain open to backdated postings. Credit expiry needs no scheduled job: the journal
records future expiry and adjustments when credit is issued, applied, restored, or revoked. Report
reads never alter credit balances or persist a daily close. Back up the finance tables together
with the rest of the SQLite database; they commit atomically with partner results and domain state.
