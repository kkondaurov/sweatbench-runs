# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

For the durable-operations release, run `mix ecto.migrate` in the deployment environment before
serving requests. Migration `20260905000002` adds the `operations` table without changing existing
reservations, credit, or settlements. Coordinate the gateway's new operation-identifier namespace
with this deployment; records for earlier releases are intentionally not reconstructed.

The `operations` table is both the retry store and the submission audit. It retains the complete
JSON in `submission`, the submitted string `type`, and the original JSON `result`. Missing or
non-string types remain in `submission` and have a null `type` column. Ascending `id` gives the
order records first committed; retries and conflicts do not add or update records. Retain these
rows along with the domain tables in database backups: deleting records would permit old retries
to apply again.

The full `mix test` suite includes migration upgrades, independent database connections, injected
transaction failures, and real `mix phx.server` processes sharing a database and restarting. Those
tests create their databases inside the repository's `tmp` directory and clean them up afterward.
