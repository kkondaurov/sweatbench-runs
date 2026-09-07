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

Apply migrations before running the new service. The finance migration preserves existing
accounting records and leaves reporting disabled. Submit `start_finance_reporting` once with the
agreed `starts_on` date to capture the current opening position. Operations earlier in the same
batch belong to the opening; operations after start become dated movements. The start and opening
entries commit together with the durable operation result, so retrying after a lost response is safe.

Read reports at `GET /api/v1/finance/daily-report?date=YYYY-MM-DD`. No expiry job, report-generation
job, or first-read initialization is needed. The report stays open and can change when partners
submit later operations with earlier posting dates. Reading the report never changes accounting
state. Preserve both finance tables along with the reservation and operation tables in backups.
After inception, the finance migration refuses a downgrade: retaining the original start's durable
result while dropping its opening position would make a later upgrade unable to resume reporting.
