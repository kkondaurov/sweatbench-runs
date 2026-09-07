# Executed by a fresh BEAM VM to verify durable state across application restarts.
alias GroupStay.{Credits, Finance, Operations, Payments, Repo, Reservations}
alias GroupStay.Operations.Record
alias GroupStay.Finance.Reporting

[input_path, output_path] = System.argv()
# Migrate before starting the application, as `mix ecto.migrate` does, so the
# migrator can start its own pool with enough connections for migration tasks.
{:ok, _, _} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))
{:ok, _} = Application.ensure_all_started(:group_stay)
operations = input_path |> File.read!() |> Jason.decode!()
stored_before = Enum.map(operations, &Operations.get_result(&1["operation_id"]))
results = Operations.apply_batch(operations)

groups =
  (operations ++ results)
  |> Enum.map(& &1["group_id"])
  |> Enum.filter(&is_binary/1)
  |> Enum.uniq()
  |> Enum.sort()
  |> Enum.flat_map(fn id ->
    case Reservations.get_group(id) do
      nil -> []
      group -> [GroupStayWeb.GroupJSON.show(%{group: group}).data]
    end
  end)

records =
  Record
  |> Repo.all()
  |> Enum.sort_by(& &1.id)
  |> Enum.map(
    &Map.take(&1, [:id, :operation_id, :operation_type, :payload, :result, :inserted_at])
  )

statements =
  records
  |> Enum.filter(
    &(&1.operation_type == "record_cash_payment" and &1.result["status"] == "applied")
  )
  |> Enum.map(fn record ->
    {:ok, statement} = Payments.statement(record.operation_id)
    statement
  end)

reports =
  Map.new(~w(2026-10-03 2026-10-04 2027-10-04 2027-10-05), fn date ->
    result =
      case Reporting.daily_report(Date.from_iso8601!(date)) do
        {:ok, report} -> report
        {:error, code} -> %{error: code}
      end

    {date, result}
  end)

File.write!(
  output_path,
  Jason.encode!(%{
    stored_before: stored_before,
    results: results,
    groups: groups,
    ledger: Finance.totals(~D[2026-10-03]),
    credit: Credits.balance("guest-22", ~D[2026-10-03]),
    records: records,
    statements: statements,
    reports: reports
  })
)
