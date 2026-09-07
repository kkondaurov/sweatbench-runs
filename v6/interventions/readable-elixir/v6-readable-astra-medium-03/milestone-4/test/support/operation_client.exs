# A separate BEAM instance exercises retry coordination without sharing a
# connection pool, process memory, or application supervision tree with the test.
[database, input, output] = System.argv()
config = Application.fetch_env!(:group_stay, GroupStay.Repo)

Application.put_env(
  :group_stay,
  GroupStay.Repo,
  Keyword.merge(config,
    database: database,
    pool: DBConnection.ConnectionPool,
    pool_size: 1,
    busy_timeout: 10_000
  )
)

{:ok, _} = Application.ensure_all_started(:group_stay)
operation = input |> File.read!() |> Jason.decode!()
result = GroupStay.Reservations.submit([operation])
File.write!(output, Jason.encode!(result))
