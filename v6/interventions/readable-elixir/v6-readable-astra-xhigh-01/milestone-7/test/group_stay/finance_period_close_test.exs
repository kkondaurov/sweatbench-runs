defmodule GroupStay.FinancePeriodCloseTest do
  use GroupStay.CommittedCase, async: false

  import GroupStay.PartnerFixtures
  import Ecto.Query

  alias GroupStay.{Operations, Repo}
  alias GroupStay.Finance.Reporting
  alias GroupStay.Finance.Reporting.{Entry, PeriodClose}
  alias GroupStay.Operations.Record

  test "upgrading preserves existing inception, entries and results" do
    apply!([
      start_finance_reporting(),
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    reports = reports()
    assert [20_260_907_060_000] = Ecto.Migrator.run(Repo, :down, step: 1, log: false)
    before = prior_storage()
    assert [20_260_907_060_000] = Ecto.Migrator.run(Repo, :up, all: true, log: false)
    assert prior_storage() == before
    assert reports() == reports
    assert Enum.all?(Repo.all(Entry), &(&1.late_adjustment == false))
    assert Repo.all(PeriodClose) == []
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    apply!([close_finance_period("2027-10-04")])
    closed = snapshot()

    assert_raise Ecto.MigrationError, ~r/cannot downgrade after a finance period closes/, fn ->
      Ecto.Migrator.run(Repo, :down, step: 1, log: false)
    end

    assert snapshot() == closed
  end

  for table <- ~w(finance_period_closes operation_records) do
    test "a close and its result roll back together when #{table} fails" do
      apply!([start_finance_reporting(), open_group()])
      close = close_finance_period("2026-10-03", %{"operation_id" => "fail"})
      inject_fault(unquote(table))

      assert_raise Exqlite.Error, ~r/injected close fault/, fn ->
        Operations.apply_batch([
          operation("record_cash_payment", %{"amount_cents" => 100}),
          close,
          operation("record_cash_payment", %{
            "operation_id" => "not-reached",
            "amount_cents" => 20
          })
        ])
      end

      assert Repo.all(PeriodClose) == []
      assert Operations.get_result("fail") == nil
      assert Operations.get_result("not-reached") == nil
      assert {:ok, report} = Reporting.daily_report(~D[2026-10-03])
      assert report.status == "open"
      assert [%{closing_held_cents: 100}] = report.cash
      Repo.query!("DROP TRIGGER injected_fault")
      [result] = apply!([close])
      before = snapshot()
      assert Operations.apply_batch([close]) == [result]
      assert snapshot() == before
      assert {:ok, %{status: "closed"}} = Reporting.daily_report(~D[2026-10-03])
    end
  end

  for table <- ~w(finance_reporting_entries operation_records) do
    test "a late credit settlement rolls back all accounting when #{table} fails" do
      apply!([
        start_finance_reporting(),
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        close_finance_period("2027-10-04")
      ])

      before = snapshot()

      cancellation =
        operation("cancel_group", %{"operation_id" => "fail", "refund_method" => "hotel_credit"})

      inject_fault(unquote(table))

      assert_raise Exqlite.Error, ~r/injected close fault/, fn ->
        Operations.apply_batch([cancellation])
      end

      assert snapshot() == before
      Repo.query!("DROP TRIGGER injected_fault")
      [result] = apply!([cancellation])
      after_success = snapshot()
      assert Operations.apply_batch([cancellation]) == [result]
      assert snapshot() == after_success
    end
  end

  test "concurrent closes at one cutoff have one winner and exact retries do not close again", %{
    repo: repo
  } do
    apply!([start_finance_reporting()])
    closes = Enum.map(1..6, fn _ -> close_finance_period("2026-10-03") end)
    results = concurrently(repo, closes)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "invalid_period")) == 5
    assert Repo.aggregate(PeriodClose, :count) == 1
    winner = Enum.find(results, &(&1["status"] == "applied"))
    close = Enum.find(closes, &(&1["operation_id"] == winner["operation_id"]))
    before = snapshot()
    assert concurrently(repo, List.duplicate(close, 6)) == List.duplicate(winner, 6)
    assert snapshot() == before
  end

  test "concurrent payments post according to the cutoff at their durable commit", %{repo: repo} do
    apply!([start_finance_reporting(), open_group()])

    operations = [
      operation("record_cash_payment", %{"amount_cents" => 100}),
      close_finance_period("2026-10-03"),
      operation("record_cash_payment", %{"amount_cents" => 200}),
      close_finance_period("2026-10-04"),
      operation("record_cash_payment", %{"amount_cents" => 300})
    ]

    concurrently(repo, operations)

    Repo.all(from record in Record, order_by: record.id)
    |> Enum.reduce(nil, fn record, cutoff ->
      case {record.operation_type, record.result["status"]} do
        {"close_finance_period", "applied"} ->
          Date.from_iso8601!(record.result["period_end_on"])

        {"record_cash_payment", "applied"} ->
          entry = Repo.get_by!(Entry, operation_id: record.operation_id)
          assert entry.posted_on == if(cutoff, do: Date.add(cutoff, 1), else: ~D[2026-10-03])
          assert entry.late_adjustment == not is_nil(cutoff)
          cutoff

        _ ->
          cutoff
      end
    end)

    assert {:ok, report} = Reporting.daily_report(~D[2026-10-05])
    assert [%{closing_held_cents: 600}] = report.cash
  end

  test "batches and sequential commits produce equivalent closed and open reports" do
    operations = [
      start_finance_reporting(),
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      close_finance_period("2026-10-03"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      close_finance_period("2027-10-04"),
      operation("charge_back_payment", %{"payment_operation_id" => "payment"}),
      close_finance_period("2026-10-03")
    ]

    assert {:error, batched} =
             Repo.transaction(fn ->
               results = Operations.apply_batch(operations)
               Repo.rollback({results, reports()})
             end)

    results = Enum.flat_map(operations, &Operations.apply_batch([&1]))
    assert {results, reports()} == batched
  end

  test "closed reports and expiry corrections survive database restart and reads never mutate state",
       %{database: database} do
    close = close_finance_period("2027-10-04")

    apply!([
      start_finance_reporting(),
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      close,
      operation("charge_back_payment", %{"payment_operation_id" => "payment"})
    ])

    before = reports()
    stored = snapshot()
    stop_supervised!(Repo)

    repo =
      start_supervised!({Repo, name: nil, database: database, pool: DBConnection.ConnectionPool})

    Repo.put_dynamic_repo(repo)
    assert reports() == before
    assert reports() == before
    assert snapshot() == stored

    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert reports() == before
    assert Operations.apply_batch([close]) == [Operations.get_result(close["operation_id"])]
  end

  defp inject_fault(table) do
    Repo.query!("""
    CREATE TRIGGER injected_fault BEFORE INSERT ON #{table}
    WHEN NEW.operation_id = 'fail'
    BEGIN SELECT RAISE(ABORT, 'injected close fault'); END
    """)
  end

  defp apply!(operations) do
    results = Operations.apply_batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp concurrently(repo, operations) do
    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          receive do: (:go -> :ok)
          [result] = Operations.apply_batch([operation])
          result
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end

  defp reports do
    Map.new(~w(2027-10-05 2026-10-04 2026-10-03 2027-10-03 2027-10-04), fn date ->
      {:ok, report} = Reporting.daily_report(Date.from_iso8601!(date))
      {date, Jason.encode!(report)}
    end)
  end

  defp prior_storage do
    tables =
      ~w(groups rooms cash_entries cash_allocations credit_lots credit_allocations credit_entitlements operation_records finance_reporting_inceptions)

    Map.new(tables, &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1").rows})
    |> Map.put(
      "finance_reporting_entries",
      Repo.query!(
        "SELECT id, operation_id, posted_on, property_id, movements FROM finance_reporting_entries ORDER BY id"
      ).rows
    )
  end

  defp snapshot do
    prior_storage()
    |> Map.put("finance_period_closes", Repo.all(PeriodClose))
    |> Map.put("finance_reporting_entries", Repo.all(from entry in Entry, order_by: entry.id))
  end
end
