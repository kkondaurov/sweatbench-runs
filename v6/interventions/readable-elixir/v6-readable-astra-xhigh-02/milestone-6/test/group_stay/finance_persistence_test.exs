defmodule GroupStay.FinancePersistenceTest do
  use GroupStay.CommittedRepoCase, async: false

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers
  import GroupStay.MigrationHelpers
  import Plug.Conn
  import Phoenix.ConnTest

  alias GroupStay.{Finance, Operations, PartnerBatches, Repo, Reservations}
  alias GroupStay.Finance.{Entry, ReportingPeriod}
  alias GroupStay.Operations.Operation

  @endpoint GroupStayWeb.Endpoint

  test "concurrent starts establish exactly one opening and exact retries stay exact" do
    seed()
    start = start_reporting()
    assert [result] = concurrently([start, start], @repo_name) |> Enum.uniq()
    assert result["status"] == "applied"
    assert Repo.aggregate(ReportingPeriod, :count) == 1
    assert report("2026-11-01")["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
    assert Operations.process(start_reporting())["code"] == "reporting_already_started"
    assert Operations.process(start) == result
  end

  test "distinct concurrent starts cannot create two inception dates" do
    seed()
    results = concurrently([start_reporting(), start_reporting("2026-12-01")], @repo_name)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reporting_already_started")) == 1
    assert Repo.aggregate(ReportingPeriod, :count) == 1
    assert report("2026-12-01")["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
  end

  test "a payment racing inception belongs to either opening or movements exactly once" do
    Operations.process(room_group())
    pay = payment(%{"amount_cents" => 100})

    assert Enum.all?(
             concurrently([start_reporting(), pay], @repo_name),
             &(&1["status"] == "applied")
           )

    [cash] = report("2026-11-01")["cash"]

    assert {cash["opening_held_cents"], cash["movements"]["received_cents"]} in [
             {0, 100},
             {100, 0}
           ]

    assert cash["closing_held_cents"] == 100
    before = snapshot()
    Operations.process(pay)
    assert snapshot() == before
  end

  test "a journal failure rolls back domain changes and aborts only the uncommitted batch tail" do
    seed()
    Operations.process(start_reporting())
    failed = payment(%{"operation_id" => "fault", "amount_cents" => 20})
    earlier = payment(%{"amount_cents" => 10})
    later = payment(%{"amount_cents" => 30})

    Repo.query!("""
    CREATE TRIGGER fail_finance_entry BEFORE INSERT ON finance_entries
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected finance failure'); END
    """)

    try do
      assert_error_sent(500, fn -> submit_http([earlier, failed, later]) end)
      assert Operations.get_result(earlier["operation_id"])["status"] == "applied"
      assert Operations.get_result("fault") == nil
      assert Operations.get_result(later["operation_id"]) == nil
      assert Reservations.get_group("group-81").deposit_paid_cents == 110

      assert report("2026-11-01")["cash"] == [
               cash_row("ams-canal", 100, %{"received_cents" => 10}, 110)
             ]
    after
      Repo.query!("DROP TRIGGER fail_finance_entry")
    end

    assert Operations.process(failed)["status"] == "applied"
    before = snapshot()
    Operations.process(failed)
    assert snapshot() == before

    assert report("2026-11-01")["cash"] == [
             cash_row("ams-canal", 100, %{"received_cents" => 30}, 130)
           ]
  end

  test "audit failure rolls back inception and opening so its retry can start reporting" do
    seed()
    start = start_reporting("2026-11-01", %{"operation_id" => "fault"})
    before = snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_finance_start BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected start receipt failure'); END
    """)

    try do
      assert_error_sent(500, fn -> submit_http([start]) end)
      assert snapshot() == before
      assert Finance.daily_report("2026-11-01") == {:error, :report_not_available}
      assert Operations.get_result("fault") == nil
    after
      Repo.query!("DROP TRIGGER fail_finance_start")
    end

    assert Operations.process(start)["status"] == "applied"
    assert report("2026-11-01")["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
  end

  test "audit failure after journal writes rolls back both movements and payment" do
    seed()
    Operations.process(start_reporting())
    before = snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_finance_receipt BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    """)

    try do
      assert_error_sent(500, fn ->
        submit_http([payment(%{"operation_id" => "fault", "amount_cents" => 20})])
      end)

      assert snapshot() == before
      assert Operations.get_result("fault") == nil
    after
      Repo.query!("DROP TRIGGER fail_finance_receipt")
    end
  end

  test "inception, movements, scheduled expiry and receipts survive repository restart", %{
    repo_options: options
  } do
    operations = [
      room_group(),
      payment(%{"operation_id" => "p", "amount_cents" => 200}),
      start_reporting(),
      room_group("destination", [100], %{"property_id" => "berlin"}),
      transfer("group-81", "destination", 100),
      cancellation(%{"group_id" => "destination", "refund_method" => "hotel_credit"}),
      reduce_cash("p", 20),
      payment(%{"amount_cents" => 9999})
    ]

    results = Enum.map(operations, &Operations.process/1)
    assert Enum.count(results, &(&1["status"] == "rejected")) == 1
    before = snapshot()
    dates = ~w(2026-11-01 2026-11-02 2027-11-01 2027-11-02)
    reports = Enum.map(dates, &report/1)
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == []
    assert Enum.map(Enum.reverse(dates), &report/1) == Enum.reverse(reports)
    assert Enum.map(operations, &Operations.process/1) == results
    assert snapshot() == before
    assert report("2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 0
  end

  test "equivalent batches and sequential submissions produce identical reports" do
    operations = [
      room_group(),
      payment(%{"operation_id" => "p", "amount_cents" => 200, "occurred_on" => "2027-01-01"}),
      start_reporting(),
      room_group("destination", [100], %{"property_id" => "berlin"}),
      transfer("group-81", "destination", 100),
      cancellation(%{"group_id" => "destination", "refund_method" => "hotel_credit"}),
      reduce_cash("p", 20, %{"occurred_on" => "2026-10-31"}),
      payment(%{"amount_cents" => 9999}),
      charge_back("p", %{"occurred_on" => "2026-11-02"})
    ]

    {:error, batch} =
      Repo.transaction(fn ->
        {:ok, results} = PartnerBatches.submit(%{"operations" => operations})
        reports = Enum.map(~w(2026-11-01 2026-11-02 2027-11-02), &report/1)
        Repo.rollback({results, reports})
      end)

    results = Enum.map(operations, &Operations.process/1)
    reports = Enum.map(~w(2026-11-01 2026-11-02 2027-11-02), &report/1)
    assert {results, reports} == batch
  end

  defp seed do
    Operations.process(room_group())
    Operations.process(payment(%{"operation_id" => "p", "amount_cents" => 100}))
  end

  defp snapshot do
    {domain_snapshot(), Repo.all(Entry), Repo.all(ReportingPeriod), Repo.all(Operation)}
  end

  defp report(date) do
    {:ok, report} = Finance.daily_report(date)
    report |> Jason.encode!() |> Jason.decode!() |> assert_balanced()
  end

  defp submit_http(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end
end
