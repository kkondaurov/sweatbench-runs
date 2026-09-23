defmodule GroupStay.DurableOperationsTest do
  # Runs against its own database file, outside the sandbox, so that restarts and concurrent
  # connections behave as they do in production.
  use ExUnit.Case, async: false

  import Ecto.Query

  import GroupStayWeb.PartnerApiHelpers, only: [open_group_op: 1, payment_op: 1]

  alias GroupStay.{FinanceReports, Groups, OperationRecords, PartnerOperations, Repo}

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

  test "closed finance reports stay byte-for-byte stable after the service restarts",
       %{path: path} do
    PartnerOperations.process_operation(open_group_op(%{"operation_id" => "op-open"}))
    start = %{"operation_id" => "start", "type" => "start_finance_reporting"}
    PartnerOperations.process_operation(Map.put(start, "starts_on", "2026-10-04"))
    PartnerOperations.process_operation(payment_op(%{"operation_id" => "op-pay"}))

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-10-05"
    }

    closed = %{"operation_id" => "close", "status" => "applied", "period_end_on" => "2026-10-05"}
    assert PartnerOperations.process_operation(close) == closed
    reports = closed_reports()

    stop_supervised!(Repo)
    start_repo!(path)

    assert PartnerOperations.process_operation(close) == closed
    assert closed_reports() == reports

    assert %{"status" => "applied"} =
             PartnerOperations.process_operation(
               payment_op(%{"amount_cents" => 1000, "occurred_on" => "2026-10-04"})
             )

    assert closed_reports() == reports

    assert {:ok, %{status: "open", late_adjustments: %{cash: [%{movements: movements}]}}} =
             FinanceReports.daily_report(~D[2026-10-06])

    assert movements["received_cents"] == 1000
  end

  test "operations committed concurrently with a close post on either side of it" do
    PartnerOperations.process_operation(open_group_op(%{"operation_id" => "op-open"}))

    PartnerOperations.process_operation(%{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-04"
    })

    repo = Repo.get_dynamic_repo()

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-10-05"
    }

    payments =
      for n <- 1..8, do: payment_op(%{"operation_id" => "op-pay-#{n}", "amount_cents" => 100})

    (payments ++ [close])
    |> Enum.shuffle()
    |> Enum.map(fn op ->
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        PartnerOperations.process_operation(op)
      end)
    end)
    |> Task.await_many(30_000)
    |> Enum.each(&assert(&1["status"] == "applied"))

    order = Map.new(operation_records(), &{&1.operation_id, &1.id})

    postings =
      Repo.all(
        from p in GroupStay.FinanceReports.Posting,
          select: {p.operation_id, p.posting_date, p.late_adjustment}
      )

    assert length(postings) == 8

    for {operation_id, posting_date, late_adjustment} <- postings do
      if order[operation_id] < order["close"],
        do: assert({posting_date, late_adjustment} == {~D[2026-10-04], false}),
        else: assert({posting_date, late_adjustment} == {~D[2026-10-06], true})
    end
  end

  defp operation_records, do: Repo.all(OperationRecords.OperationRecord)

  defp closed_reports do
    for date <- Date.range(~D[2026-10-04], ~D[2026-10-05]) do
      {:ok, report} = FinanceReports.daily_report(date)
      Jason.encode!(report)
    end
  end
end
