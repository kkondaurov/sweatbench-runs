# Invoked by PersistenceTest in a fresh VM. Read results before submitting anything
# so replay cannot depend on domain modules or process-local state being warmed up.
[input_path, output_path, report_dates] = System.argv()
operations = input_path |> File.read!() |> Jason.decode!()

stored_results =
  Enum.map(operations, fn operation ->
    {:ok, result} = GroupStay.Reservations.get_operation(operation["operation_id"])
    result
  end)

reports =
  Enum.map(Jason.decode!(report_dates), fn date ->
    conn =
      Plug.Test.conn(:get, "/api/v1/finance/daily-report?date=#{date}")
      |> GroupStayWeb.Endpoint.call(GroupStayWeb.Endpoint.init([]))

    200 = conn.status
    conn.resp_body
  end)

File.write!(
  output_path,
  Jason.encode!(%{
    stored_results: stored_results,
    replayed_results: GroupStay.Reservations.submit_batch(operations),
    reports: reports
  })
)
