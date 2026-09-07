defmodule GroupStay.FinancePeriodClosePersistenceTest do
  use GroupStay.PersistenceCase

  import GroupStay.OperationFixtures

  alias GroupStay.{Finance, Repo, Reservations}
  alias GroupStay.Finance.{Entry, PeriodClose, ReportingStart}

  alias GroupStay.Reservations.{
    CashAllocation,
    CashEntry,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    RoomCreditAllocation
  }

  test "concurrent identical closes publish once and return the same stored result", %{repo: repo} do
    submit([open_group(), payment(), start_reporting()])
    close = close_period()
    [first | retries] = race(repo, fn _ -> submit([close]) end)
    assert Enum.all?(retries, &(&1 == first))
    assert [%{"status" => "applied", "period_end_on" => "2026-11-30"}] = first
    assert Repo.aggregate(PeriodClose, :count) == 1
    assert report(~D[2026-11-30]).status == "closed"
    before = snapshot()
    race(repo, fn _ -> submit([close]) end)
    assert snapshot() == before
  end

  test "competing close identifiers cannot publish the same cutoff twice", %{repo: repo} do
    submit([start_reporting()])
    results = race(repo, fn _ -> submit([close_period()]) end) |> List.flatten()
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "invalid_period")) == 3
    assert Repo.aggregate(PeriodClose, :count) == 1
  end

  test "a payment racing a close posts wholly before or after its publication boundary", %{
    repo: repo
  } do
    submit([open_group(), start_reporting()])
    close = close_period()
    payment = payment(%{"amount_cents" => 100})

    results =
      race(repo, fn index -> submit([if(rem(index, 2) == 0, do: close, else: payment)]) end)

    assert Enum.all?(List.flatten(results), &(&1["status"] == "applied"))

    november = report(~D[2026-11-01])
    december = report(~D[2026-12-01])
    assert [%{closing_held_cents: 100, movements: %{received_cents: 0}}] = december.cash

    case november.cash do
      [] ->
        assert [%{movements: %{received_cents: 100}}] = december.late_adjustments.cash
        assert hd(december.cash).opening_held_cents == 0

      [%{movements: %{received_cents: 100}, closing_held_cents: 100}] ->
        assert december.late_adjustments.cash == []
        assert hd(december.cash).opening_held_cents == 100
    end

    assert Reservations.ledger().cash_held_cents == 100
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "a failed close rolls back publication and aborts the batch after earlier commits" do
    submit([open_group(), start_reporting()])
    fail_audit()
    close = close_period(%{"operation_id" => "fault"})

    operations = [
      payment(%{"operation_id" => "before", "amount_cents" => 20}),
      close,
      payment(%{"operation_id" => "after", "amount_cents" => 30})
    ]

    assert_raise Exqlite.Error, ~r/forced close audit failure/, fn -> submit(operations) end
    assert Repo.all(PeriodClose) == []
    assert Reservations.get_operation_result("fault") == nil
    assert Reservations.get_operation_result("after") == nil
    assert report(~D[2026-11-01]).status == "open"
    assert hd(report(~D[2026-11-01]).cash).movements.received_cents == 20

    Repo.query!("DROP TRIGGER reject_close_audit")
    assert Enum.all?(submit(operations), &(&1["status"] == "applied"))
    assert hd(report(~D[2026-11-01]).cash).closing_held_cents == 20
    assert hd(report(~D[2026-12-01]).late_adjustments.cash).movements.received_cents == 30
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "publication storage failures leave no remembered result or cutoff" do
    submit([start_reporting()])

    Repo.query!("""
    CREATE TRIGGER reject_period_close BEFORE INSERT ON finance_period_closes
    BEGIN SELECT RAISE(ABORT, 'forced close storage failure'); END
    """)

    before = snapshot()

    assert_raise Exqlite.Error, ~r/forced close storage failure/, fn ->
      submit([close_period()])
    end

    assert snapshot() == before
    assert report(~D[2026-11-30]).status == "open"
  end

  test "failed adjustments leave published reports and current domain state unchanged" do
    submit([open_group(), payment(), start_reporting(), close_period()])
    published = encoded_report(~D[2026-11-01])
    operation = cancellation(%{"operation_id" => "fault", "refund_method" => "hotel_credit"})
    before = snapshot()
    fail_audit()
    assert_raise Exqlite.Error, fn -> submit([operation]) end
    assert snapshot() == before
    assert encoded_report(~D[2026-11-01]) == published
    assert report(~D[2026-12-01]).late_adjustments.cash == []

    Repo.query!("DROP TRIGGER reject_close_audit")
    assert [%{"status" => "applied"}] = result = submit([operation])
    before = snapshot()
    assert submit([operation]) == result

    assert [%{"code" => "operation_id_conflict"}] =
             submit([Map.put(operation, "occurred_on", "2026-11-02")])

    assert snapshot() == before
    assert report(~D[2026-12-01]).late_adjustments.credit.issued_cents == 5500
    assert report(~D[2027-11-02]).credit.movements.expired_cents == 5500
    assert encoded_report(~D[2026-11-01]) == published
  end

  test "upgrade preserves inception and existing reporting entries as ordinary movements" do
    submit([
      open_group(),
      payment(%{"amount_cents" => 100}),
      start_reporting(),
      cancellation(%{"refund_method" => "hotel_credit"})
    ])

    before = snapshot()
    reports = reports()

    assert Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_006, log: false) == [
             20_260_907_000_006
           ]

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [20_260_907_000_006]
    assert snapshot() == before
    assert reports() == reports
    assert Enum.all?(Repo.all(Entry), &(not &1.late_adjustment))

    submit([close_period()])
    assert report(~D[2026-11-01]).credit.movements.issued_cents == 110
    assert report(~D[2026-11-01]).late_adjustments.credit.issued_cents == 0
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  test "downgrading cannot discard a published cutoff while its successful result still replays" do
    submit([start_reporting(), close_period()])
    before = snapshot()

    assert_raise Ecto.MigrationError,
                 ~r/cannot remove finance period close after publication/,
                 fn ->
                   Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_006, log: false)
                 end

    assert snapshot() == before
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  test "reports and exact results survive restart and agree for batched and sequential submissions",
       %{
         template: template,
         database: database,
         options: options
       } do
    operations = lifecycle_operations()
    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    expected = reports()
    before = snapshot()
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert reports() == expected
    assert submit(operations) == results
    assert snapshot() == before

    # Reads, including days first read after publication, never materialize data.
    for date <- Date.range(~D[2026-11-01], ~D[2026-12-02]) |> Enum.reverse() do
      assert report(date).status == "closed"
    end

    assert snapshot() == before

    sequential_database = Path.join(Path.dirname(database), "sequential.db")
    File.cp!(template, sequential_database)

    sequential =
      start_supervised!(
        Supervisor.child_spec(
          {Repo, Keyword.put(options, :database, sequential_database)},
          id: :sequential
        )
      )

    Repo.put_dynamic_repo(sequential)
    assert Enum.flat_map(operations, &submit([&1])) == results
    assert reports() == expected
  end

  test "closed report bytes and posting classifications survive independent application lifetimes",
       %{database: database} do
    directory = Path.dirname(database)
    script = Path.join(directory, "period_close_restart.exs")
    input = Path.join(directory, "period_close_operations.json")
    output = Path.join(directory, "period_close_results.json")
    File.write!(input, Jason.encode!(lifecycle_operations()))

    File.write!(script, """
    [input, output] = System.argv()
    results = input |> File.read!() |> Jason.decode!() |> GroupStay.Reservations.submit_batch()
    reports = for date <- [~D[2026-11-01], ~D[2026-12-01], ~D[2027-11-02], ~D[2027-11-03]] do
      conn = Plug.Test.conn("GET", "/api/v1/finance/daily-report?date=" <> Date.to_iso8601(date))
      conn = GroupStayWeb.Endpoint.call(conn, GroupStayWeb.Endpoint.init([]))
      if conn.status != 200, do: raise("report request failed")
      conn.resp_body
    end
    File.write!(output, Jason.encode!(%{results: results, reports: reports}))
    """)

    run = fn ->
      {log, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", script, input, output],
          env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", database}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      output |> File.read!() |> Jason.decode!()
    end

    result = run.()
    before = snapshot()
    assert run.() == result
    assert snapshot() == before
    assert Enum.all?(result["results"], &(&1["status"] == "applied"))

    assert Enum.at(result["reports"], 2) |> Jason.decode!() |> get_in(["data", "status"]) ==
             "closed"

    assert Enum.at(result["reports"], 3)
           |> Jason.decode!()
           |> get_in(["data", "late_adjustments", "credit", "expired_cents"]) == -80
  end

  defp lifecycle_operations do
    [
      open_group(),
      payment(%{"operation_id" => "payment", "amount_cents" => 100}),
      start_reporting(),
      close_period(),
      cancellation(%{"refund_method" => "hotel_credit"}),
      close_period(%{"period_end_on" => "2026-12-02"}),
      open_group(%{
        "group_id" => "destination",
        "arrival_on" => "2028-02-01",
        "departure_on" => "2028-02-02"
      }),
      close_period(%{"period_end_on" => "2027-11-02"}),
      credit_application(%{
        "group_id" => "destination",
        "amount_cents" => 80,
        "occurred_on" => "2027-11-01"
      })
    ]
  end

  defp submit(operations), do: Reservations.submit_batch(operations)

  defp report(date) do
    assert {:ok, report} = Finance.daily_report(date)
    report
  end

  defp encoded_report(date) do
    %{report: report(date)} |> GroupStayWeb.DailyFinanceReportJSON.show() |> Jason.encode!()
  end

  defp reports,
    do:
      Enum.map(
        [
          ~D[2026-11-01],
          ~D[2026-11-30],
          ~D[2026-12-01],
          ~D[2026-12-02],
          ~D[2027-11-02],
          ~D[2027-11-03]
        ],
        &encoded_report/1
      )

  defp snapshot do
    Enum.map(
      [
        Group,
        CashEntry,
        CashAllocation,
        CreditLot,
        CreditAllocation,
        RoomCreditAllocation,
        CreditEntitlement,
        OperationRecord,
        ReportingStart,
        Entry,
        PeriodClose
      ],
      &Repo.all/1
    )
  end

  defp fail_audit do
    Repo.query!("""
    CREATE TRIGGER reject_close_audit BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'forced close audit failure'); END
    """)
  end
end
