# Development and runtime

GroupStay uses the generated Phoenix application and its existing module names. Keep these standard
entry points working as the product evolves:

- `mix test` runs the application's test suite, including tests that use `GroupStayWeb.ConnCase`;
- `mix phx.server` starts the HTTP service in every environment, including `test`;
- `PORT` selects the HTTP port when the service is started;
- `GROUP_STAY_DATABASE_PATH` selects the SQLite database in the test environment.

Database changes belong in Ecto migrations. A database created by an earlier release must be
upgradeable by running the migrations from the new release.

## Durable operations rollout

Run `mix ecto.migrate` against the service database before accepting traffic for this release.
The new `operations` table starts empty; existing reservations, credit lots and applications
are preserved. Coordinate the gateway's new operation-identifier namespace at deployment.
Operations received by earlier releases are not backfilled and have no stored retry result.

Operation records are the durable retry and audit history. Each contains the complete submitted
JSON, its type when supplied as a string, and the exact JSON result. The generated `id` orders
first commits, including rejections. Malformed type values remain in the submitted JSON.
Retries and conflicts leave the original record and order unchanged.

Keep this history with the reservation and credit tables when backing up or restoring SQLite.
Removing operation records removes the retry guarantee for those identifiers. An unexpected
server fault returns `500`; retrying the batch safely resumes after its previously committed
operations. `GET /api/v1/operations/:operation_id` can inspect a committed outcome after a lost
response, including after a service restart.
