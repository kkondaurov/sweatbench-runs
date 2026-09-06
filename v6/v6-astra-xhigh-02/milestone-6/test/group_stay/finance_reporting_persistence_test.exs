defmodule GroupStay.FinanceReportingPersistenceTest do
  use ExUnit.Case, async: false
  import GroupStay.ReservationFixtures
  import Ecto.Query
  alias GroupStay.{FinanceReporting, PartnerOperations, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Inception, Movement}
  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Reservations.RoomAllocation

  @moduletag capture_log: true
  @migration 20_260_905_000_005

  setup do
    directory = Path.expand("tmp/finance-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "test.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    stop_supervised!(Repo)
    options = Keyword.put(options, :pool_size, 4)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    %{repo: repo, options: options}
  end

  test "an upgraded database preserves legacy funding and freezes an opening that survives restart",
       %{options: options} do
    applied([
      open_operation(),
      pay("legacy", 100),
      open_operation(%{"group_id" => "issuer"}),
      operation("record_cash_payment", %{"group_id" => "issuer", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      operation("apply_hotel_credit", %{"amount_cents" => 80})
    ])

    Repo.update_all(from(a in RoomAllocation, where: a.payment_operation_id == "legacy"),
      set: [payment_operation_id: nil]
    )

    Repo.delete_all(from o in Operation, where: o.operation_id == "legacy")
    before = Reservations.ledger(~D[2026-10-04])
    assert Ecto.Migrator.run(Repo, :down, to: @migration, log: false) == [@migration]
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [@migration]
    assert Reservations.ledger(~D[2026-10-04]) == before

    assert {:error, %{code: "report_not_available"}} =
             FinanceReporting.daily_report(~D[2026-10-04])

    operations = [
      start(),
      pay("new", 50),
      operation("cancel_group", %{"occurred_on" => "2026-10-05"})
    ]

    results = applied(operations)
    opening = report(~D[2026-10-04])
    assert [%{opening_held_cents: 100, closing_held_cents: 150}] = opening.cash
    assert opening.credit.opening_liability_cents == 110
    future = report(~D[2027-10-05])
    assert future.credit.movements["expired_cents"] == 110

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.process_batch(operations) == results
    assert report(~D[2026-10-04]) == opening
    assert report(~D[2027-10-05]) == future
    assert [%{code: "reporting_already_started"}] = Reservations.process_batch([start()])
  end

  test "concurrent starts enable reporting once and concurrent retries post once", %{repo: repo} do
    applied([open_operation(), pay("before", 100)])
    starts = for _ <- 1..8, do: start()
    results = race(repo, starts)
    assert [winner] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7
    assert Repo.aggregate(Inception, :count) == 1
    winning_start = Enum.find(starts, &(&1["operation_id"] == winner.operation_id))
    assert Enum.uniq(race(repo, List.duplicate(winning_start, 8))) == [winner]

    assert [payment] = race(repo, List.duplicate(pay("after", 50), 8)) |> Enum.uniq()
    assert payment.status == "applied"
    assert Repo.aggregate(Movement, :count) == 1

    assert [
             %{
               opening_held_cents: 100,
               closing_held_cents: 150,
               movements: %{"received_cents" => 50}
             }
           ] = report(~D[2026-10-04]).cash
  end

  test "a concurrent start and payments put each committed cent in opening or movements once", %{
    repo: repo
  } do
    applied([open_operation()])
    results = race(repo, [start() | for(i <- 1..8, do: pay("p-#{i}", 10))])
    assert Enum.all?(results, &(&1.status == "applied"))

    assert [%{opening_held_cents: opening, movements: movements, closing_held_cents: 80}] =
             report(~D[2026-10-04]).cash

    assert opening + movements["received_cents"] == 80
  end

  test "an audit failure rolls back finance and domain effects while preserving the batch prefix" do
    applied([open_operation(), start()])
    prefix = pay("prefix", 100)

    cancellation =
      operation("cancel_group", %{"operation_id" => "fail", "refund_method" => "hotel_credit"})

    later = open_operation(%{"group_id" => "later"})

    Repo.query!("""
    CREATE TRIGGER fail_finance_audit BEFORE INSERT ON partner_operations
    WHEN NEW.operation_id = 'fail'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn ->
      Reservations.process_batch([prefix, cancellation, later])
    end

    assert Reservations.get_group("group-81").cash_paid_cents == 100
    assert Reservations.get_group("later") == nil
    assert PartnerOperations.get_result("fail") == nil
    assert [%{operation_id: "prefix"}] = Repo.all(Movement)
    assert report(~D[2026-10-04]).credit.closing_liability_cents == 0

    Repo.query!("DROP TRIGGER fail_finance_audit")
    applied([prefix, cancellation, later])
    report = report(~D[2026-10-04])

    assert [
             %{
               closing_held_cents: 0,
               movements: %{"received_cents" => 100, "converted_to_credit_cents" => 100}
             }
           ] = report.cash

    assert report.credit.movements["issued_cents"] == 110
    assert report.credit.closing_liability_cents == 110
    assert report(~D[2027-10-05]).credit.movements["expired_cents"] == 110
  end

  test "a reporting write failure rolls back a start and allows its original operation to retry" do
    applied([
      open_operation(),
      pay("p", 100),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    start = start()

    Repo.query!("""
    CREATE TRIGGER fail_finance_write BEFORE INSERT ON finance_movements
    BEGIN SELECT RAISE(ABORT, 'injected reporting failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([start]) end
    assert Repo.all(Inception) == []
    assert Repo.all(Movement) == []
    assert PartnerOperations.get_result(start["operation_id"]) == nil
    Repo.query!("DROP TRIGGER fail_finance_write")
    applied([start])
    assert report(~D[2026-10-04]).credit.opening_liability_cents == 110
  end

  test "a report reads inception and movements from one database snapshot", %{repo: repo} do
    applied([open_operation(), start()])
    parent = self()
    barrier = make_ref()
    handler = "finance-read-#{Ecto.UUID.generate()}"

    reader =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        receive do
          {:start, ^barrier} -> report(~D[2026-10-04])
        end
      end)

    :telemetry.attach(
      handler,
      [:group_stay, :repo, :query],
      fn _, _, metadata, reader_pid ->
        if self() == reader_pid and String.starts_with?(metadata.query, "SELECT") and
             String.contains?(metadata.query, "finance_reporting") do
          send(parent, {:snapshot, barrier})

          receive do
            {:continue, ^barrier} -> :ok
          after
            5000 -> raise "report reader was not released"
          end
        end
      end,
      reader.pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(reader.pid, {:start, barrier})
    assert_receive {:snapshot, ^barrier}, 1000
    applied([pay("p", 100)])
    send(reader.pid, {:continue, barrier})
    assert Task.await(reader).cash == []
    assert [%{closing_held_cents: 100}] = report(~D[2026-10-04]).cash
  end

  test "batch and sequential submissions produce identical inception and reports" do
    operations = [
      open_operation(),
      pay("before", 100),
      start(),
      pay("after", 50),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      operation("charge_back_payment", %{
        "payment_operation_id" => "before",
        "occurred_on" => "2026-10-06"
      }),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})
    ]

    dates = [~D[2026-10-04], ~D[2026-10-06], ~D[2027-10-05], ~D[2027-10-06]]

    {:error, expected} =
      Repo.transact(
        fn ->
          results = applied(operations)
          {:error, {results, Enum.map(dates, &report/1)}}
        end,
        mode: :immediate
      )

    results = Enum.flat_map(operations, &applied([&1]))
    assert {results, Enum.map(dates, &report/1)} == expected
  end

  defp start,
    do: %{
      "operation_id" => "start-#{Ecto.UUID.generate()}",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-04"
    }

  defp pay(id, amount),
    do: operation("record_cash_payment", %{"operation_id" => id, "amount_cents" => amount})

  defp applied(operations) do
    results = Reservations.process_batch(operations)
    assert Enum.all?(results, &(&1.status == "applied")), inspect(results)
    results
  end

  defp report(on) do
    assert {:ok, report} = FinanceReporting.daily_report(on)
    report
  end

  defp race(repo, operations) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, barrier})

          receive do
            {:go, ^barrier} -> hd(Reservations.process_batch([operation]))
          after
            5000 -> raise "concurrent operation was not released"
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, ^barrier}, 5000)
    for task <- tasks, do: send(task.pid, {:go, barrier})
    Task.await_many(tasks, 10_000)
  end

  defp remove_database_directory(directory, retries \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        # SQLite's WAL cleanup can race directory removal after pool shutdown.
        Process.sleep(20)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end
end
