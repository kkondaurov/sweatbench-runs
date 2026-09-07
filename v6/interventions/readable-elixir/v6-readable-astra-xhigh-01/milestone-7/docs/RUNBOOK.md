# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

Finance period close is persisted by the `AddFinancePeriodClose` migration. Run `mix ecto.migrate`
before starting the upgraded service. Existing reporting entries remain ordinary movements, and
existing inception balances and operation results are preserved.

Closes and finance entries commit in the same immediate SQLite transaction boundary used for
partner operations. Reports read the immutable journal; publication requires no scheduled job or
daily snapshot generation. Credit expiry remains scheduled in the journal, and corrections to a
closed expiry date appear on the first open day.

The period-close migration refuses to downgrade after a successful close, because an older
release could rewrite published days and could not restore the close from an exact retry.
