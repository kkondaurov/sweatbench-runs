defmodule GroupStay.FinancePeriodClosePersistenceTest do
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

  test "concurrent retries close once, and distinct closes at the same cutoff cannot both apply" do
    seed()
    entries = Repo.all(Entry)
    close = close_period()
    assert [receipt] = concurrently([close, close], @repo_name) |> Enum.uniq()
    assert receipt["status"] == "applied"
    assert Operations.process(close) == receipt
    assert Repo.all(Entry) == entries

    results = concurrently([close_period("2026-11-02"), close_period("2026-11-02")], @repo_name)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "invalid_period")) == 1
    assert Repo.get!(ReportingPeriod, 1).closed_through == ~D[2026-11-02]
    assert Repo.all(Entry) == entries
    assert report("2026-11-01")["status"] == "closed"
  end

  test "a payment racing a close uses the cutoff from its own commit order" do
    seed()
    close = close_period()
    pay = payment(%{"operation_id" => "racing-payment", "amount_cents" => 20})

    assert Enum.all?(concurrently([close, pay], @repo_name), &(&1["status"] == "applied"))
    close_id = Repo.get_by!(Operation, operation_id: close["operation_id"]).id
    payment_id = Repo.get_by!(Operation, operation_id: pay["operation_id"]).id
    entry = Repo.get_by!(Entry, operation_id: pay["operation_id"])

    if payment_id < close_id do
      assert entry.posted_on == ~D[2026-11-01]
      refute entry.late_adjustment

      assert report("2026-11-01")["cash"] == [
               cash_row("ams-canal", 100, %{"received_cents" => 20}, 120)
             ]

      assert report("2026-11-02")["late_adjustments"] == late_adjustments()
    else
      assert entry.posted_on == ~D[2026-11-02]
      assert entry.late_adjustment
      assert report("2026-11-01")["cash"] == [cash_row("ams-canal", 100, %{}, 100)]

      assert report("2026-11-02")["late_adjustments"] ==
               late_adjustments([late_cash_row("ams-canal", %{"received_cents" => 20})])
    end

    before = snapshot()
    Enum.each([close, pay], &Operations.process/1)
    assert snapshot() == before
    assert Reservations.ledger().cash_held_cents == 120
  end

  test "a failed close receipt rolls back the cutoff and aborts only the uncommitted batch tail" do
    seed()
    close = close_period("2026-11-01", %{"operation_id" => "fault"})
    earlier = payment(%{"amount_cents" => 10})
    later = payment(%{"amount_cents" => 20})

    Repo.query!("""
    CREATE TRIGGER fail_close_receipt BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected close receipt failure'); END
    """)

    try do
      assert_error_sent(500, fn -> submit_http([earlier, close, later]) end)
      assert Repo.get!(ReportingPeriod, 1).closed_through == nil
      assert Operations.get_result("fault") == nil
      assert Operations.get_result(later["operation_id"]) == nil
      assert Operations.get_result(earlier["operation_id"])["status"] == "applied"
      assert report("2026-11-01")["status"] == "open"

      assert report("2026-11-01")["cash"] == [
               cash_row("ams-canal", 100, %{"received_cents" => 10}, 110)
             ]
    after
      Repo.query!("DROP TRIGGER fail_close_receipt")
    end

    assert Operations.process(close)["status"] == "applied"
    assert Operations.process(later)["status"] == "applied"

    assert report("2026-11-02")["late_adjustments"] ==
             late_adjustments([late_cash_row("ams-canal", %{"received_cents" => 20})])
  end

  test "a cutoff write failure leaves the old publication intact and can be retried" do
    seed()
    Operations.process(close_period())
    before = snapshot()
    close = close_period("2026-11-02")

    Repo.query!("""
    CREATE TRIGGER fail_cutoff BEFORE UPDATE ON finance_reporting
    BEGIN SELECT RAISE(ABORT, 'injected cutoff failure'); END
    """)

    try do
      assert_error_sent(500, fn -> submit_http([close]) end)
      assert snapshot() == before
      assert Operations.get_result(close["operation_id"]) == nil
    after
      Repo.query!("DROP TRIGGER fail_cutoff")
    end

    assert Operations.process(close)["status"] == "applied"
    assert Repo.get!(ReportingPeriod, 1).closed_through == ~D[2026-11-02]
  end

  test "a failed late journal entry rolls back its payment and receipt without changing published reports" do
    seed()
    Operations.process(close_period())
    before = snapshot()
    published = report_bytes("2026-11-01")
    pay = payment(%{"operation_id" => "fault", "amount_cents" => 20})

    Repo.query!("""
    CREATE TRIGGER fail_late_entry BEFORE INSERT ON finance_entries
    WHEN NEW.late_adjustment = 1
    BEGIN SELECT RAISE(ABORT, 'injected late entry failure'); END
    """)

    try do
      assert_error_sent(500, fn -> submit_http([pay]) end)
      assert snapshot() == before
      assert Operations.get_result("fault") == nil
      assert report_bytes("2026-11-01") == published
    after
      Repo.query!("DROP TRIGGER fail_late_entry")
    end

    assert Operations.process(pay)["status"] == "applied"
    assert report("2026-11-02")["cash"] == [cash_row("ams-canal", 100, %{}, 120)]
    assert report_bytes("2026-11-01") == published
  end

  test "cutoffs, late adjustments and closed report bytes survive restart and later closes", %{
    repo_options: options
  } do
    operations = [
      room_group(),
      payment(%{"operation_id" => "p", "amount_cents" => 100}),
      start_reporting(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      close_period("2027-11-02"),
      room_group("target", [80], %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      close_period("2027-11-03"),
      close_period("2026-11-01")
    ]

    results = Enum.map(operations, &Operations.process/1)
    assert Enum.count(results, &(&1["status"] == "applied")) == 8
    before = snapshot()
    dates = ~w(2026-11-01 2026-11-02 2027-11-01 2027-11-02 2027-11-03)
    published = Enum.map(dates, &report_bytes/1)
    Supervisor.stop(Process.whereis(@repo_name))
    start_repo(options)

    assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == []
    assert Enum.map(Enum.reverse(dates), &report_bytes/1) == Enum.reverse(published)
    assert Enum.map(operations, &Operations.process/1) == results
    assert snapshot() == before

    assert Operations.process(cancellation(%{"group_id" => "target"}))["status"] == "applied"

    assert report("2027-11-04")["late_adjustments"] ==
             late_adjustments([], %{"expired_cents" => 80})

    assert report("2027-11-04")["credit"] == credit_row(80, %{}, 0)
    assert Operations.process(close_period("2027-11-05"))["status"] == "applied"
    assert Enum.map(dates, &report_bytes/1) == published
    assert Reservations.ledger(~D[2027-11-05]).credit_liability_cents == 0
  end

  test "equivalent batch and sequential submissions preserve the same publication and late history" do
    operations = [
      room_group(),
      start_reporting(),
      payment(%{"operation_id" => "p", "amount_cents" => 100}),
      close_period(),
      reduce_cash("p", 20),
      close_period("2026-11-02"),
      cancellation(),
      close_period(),
      charge_back("p")
    ]

    dates = ~w(2026-11-01 2026-11-02 2026-11-03 2026-11-04)

    {:error, batch} =
      Repo.transaction(fn ->
        {:ok, results} = PartnerBatches.submit(%{"operations" => operations})
        Repo.rollback({results, Enum.map(dates, &report_bytes/1)})
      end)

    results = Enum.map(operations, &Operations.process/1)
    assert {results, Enum.map(dates, &report_bytes/1)} == batch
  end

  defp seed do
    Operations.process(room_group())
    Operations.process(payment(%{"amount_cents" => 100}))
    Operations.process(start_reporting())
  end

  defp snapshot,
    do: {domain_snapshot(), Repo.all(Entry), Repo.all(ReportingPeriod), Repo.all(Operation)}

  defp report(date) do
    {:ok, report} = Finance.daily_report(date)
    report |> Jason.encode!() |> Jason.decode!() |> assert_balanced()
  end

  defp report_bytes(date) do
    response = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    assert response.status == 200
    response.resp_body
  end

  defp submit_http(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end
end
