# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance reporting is enabled explicitly by the first applied `start_finance_reporting`
operation; deploying its migration does not enable it or reconstruct historical movements.
The opening position and journal are stored in the same SQLite database as reservations
and operation records, so retain them together in backups. Journal writes commit atomically
with partner operations and survive service restarts.

No scheduled expiry worker or daily rollover is required. Reports sum durable operation
movements and scheduled credit-expiry adjustments without changing state. Reports remain
open: late submissions may change a previously retrieved day.
