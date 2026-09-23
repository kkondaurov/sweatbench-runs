defmodule GroupStay.DurableOperationsTest do
  # Runs against its own database file, outside the sandbox, so that restarts and concurrent
  # connections behave as they do in production.
  use ExUnit.Case, async: false

  import GroupStayWeb.PartnerApiHelpers, only: [open_group_op: 1, payment_op: 1]

  alias GroupStay.{Groups, OperationRecords, PartnerOperations, Repo}

  @migrations_path Application.app_dir(:group_stay, "priv/repo/migrations")

  setup do
    path =
      Path.join(System.tmp_dir!(), "group_stay_durable_#{System.unique_integer([:positive])}.db")

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)

    repo = start_repo!(path)
    Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, dynamic_repo: repo, log: false)

    %{path: path}
  end

  defp start_repo!(path) do
    repo =
      start_supervised!(
        {Repo, name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 4}
      )

    Repo.put_dynamic_repo(repo)
    repo
  end

  test "retries return the original result after the database connection restarts",
       %{path: path} do
    PartnerOperations.process_operation(open_group_op(%{"operation_id" => "op-open"}))
    pay = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 5000})
    original = PartnerOperations.process_operation(pay)
    assert %{"status" => "applied", "revision" => 2} = original

    stop_supervised!(Repo)
    start_repo!(path)

    assert PartnerOperations.process_operation(pay) == original
    assert {:ok, original} == OperationRecords.fetch_result("op-pay")

    assert PartnerOperations.process_operation(Map.put(pay, "amount_cents", 1)) ==
             %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

    assert {:ok, %{revision: 2, deposit_paid_cents: 5000}} = Groups.fetch_group("group-81")
  end

  test "concurrent submissions of one identifier take effect at most once" do
    PartnerOperations.process_operation(open_group_op(%{"operation_id" => "op-open"}))
    repo = Repo.get_dynamic_repo()

    submissions =
      for n <- 1..12 do
        amount = if rem(n, 2) == 0, do: 1000, else: 2000
        payment_op(%{"operation_id" => "op-pay", "amount_cents" => amount})
      end

    results =
      submissions
      |> Enum.map(fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          {op, PartnerOperations.process_operation(op)}
        end)
      end)
      |> Task.await_many(30_000)

    assert [%{"status" => "applied", "amount_cents" => winner} = applied] =
             results
             |> Enum.map(&elem(&1, 1))
             |> Enum.filter(&(&1["status"] == "applied"))
             |> Enum.uniq()

    for {op, result} <- results do
      if op["amount_cents"] == winner,
        do: assert(result == applied),
        else: assert(result["code"] == "operation_id_conflict")
    end

    assert {:ok, %{revision: 2, deposit_paid_cents: ^winner}} = Groups.fetch_group("group-81")
    assert Groups.ledger_totals(~D[2026-10-04]).cash_held_cents == winner
    assert Repo.aggregate(OperationRecords.OperationRecord, :count) == 2
  end
end
