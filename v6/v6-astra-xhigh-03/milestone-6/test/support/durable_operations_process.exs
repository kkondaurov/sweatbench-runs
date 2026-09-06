# Runs in a separate BEAM with the normal application and a caller-selected database.
[input_path, output_path | barrier_paths] = System.argv()

{:ok, _, _} =
  Ecto.Migrator.with_repo(GroupStay.Repo, fn repo ->
    Ecto.Migrator.run(repo, "priv/repo/migrations", :up, all: true, log: false)
  end)

{:ok, _} = Application.ensure_all_started(:group_stay)

case barrier_paths do
  [ready_path, go_path] ->
    File.write!(ready_path, "ready")
    deadline = System.monotonic_time(:millisecond) + 20_000

    wait = fn wait ->
      unless File.exists?(go_path) do
        if System.monotonic_time(:millisecond) >= deadline, do: raise("barrier timed out")
        Process.sleep(20)
        wait.(wait)
      end
    end

    wait.(wait)

  [] ->
    :ok
end

operations = input_path |> File.read!() |> Jason.decode!()
results = GroupStay.submit_operations(operations)

import Ecto.Query

output = %{
  results: results,
  lookups: Enum.map(operations, &GroupStay.get_operation(&1["operation_id"])),
  group: GroupStay.get_group("group-81"),
  groups:
    GroupStay.Repo.all(from group in GroupStay.Group, order_by: group.group_id)
    |> Enum.map(&GroupStay.get_group(&1.group_id)),
  payments:
    Enum.flat_map(operations, fn op ->
      if op["type"] == "record_cash_payment" do
        case GroupStay.get_payment(op["operation_id"]) do
          {:ok, statement} -> [statement]
          {:error, _} -> []
        end
      else
        []
      end
    end),
  ledger: GroupStay.ledger(~D[2026-11-26]),
  credit: GroupStay.guest_credit("guest-22", ~D[2026-11-26]),
  finance_reports:
    for date <- [~D[2026-11-26], ~D[2026-11-27], ~D[2027-11-27]], into: %{} do
      {Date.to_iso8601(date),
       case GroupStay.FinanceReporting.daily_report(date) do
         {:ok, report} -> report
         {:error, _} -> nil
       end}
    end,
  audit:
    GroupStay.Repo.all(
      from op in GroupStay.Operation,
        order_by: op.id,
        select: map(op, [:id, :operation_id, :type, :payload, :result])
    )
}

File.write!(output_path, Jason.encode!(output))
