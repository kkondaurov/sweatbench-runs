defmodule GroupStay.FinancePersistenceTest do
  use GroupStay.PersistenceCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.{Finance, Repo, Reservations}
  alias GroupStay.Finance.{Entry, ReportingStart}

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

  test "concurrent identical starts capture one opening and return one durable result", %{
    repo: repo
  } do
    submit([open_group(), payment(%{"amount_cents" => 100})])
    start = start_reporting()
    [first | retries] = race(repo, fn _ -> submit([start]) end)
    assert Enum.all?(retries, &(&1 == first))
    assert [%{"status" => "applied"}] = first
    assert Repo.aggregate(ReportingStart, :count) == 1
    assert [%{opening_held_cents: 100, closing_held_cents: 100}] = report(~D[2026-11-01]).cash
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "competing start identifiers enable reporting only once", %{repo: repo} do
    submit([open_group(), payment(%{"amount_cents" => 100})])
    results = race(repo, fn _ -> submit([start_reporting()]) end) |> List.flatten()
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reporting_already_started")) == 3
    assert Repo.aggregate(Entry, :count) == 1
    assert Repo.aggregate(ReportingStart, :count) == 1
  end

  test "a payment racing inception belongs exactly once to opening or movements", %{repo: repo} do
    submit([open_group(), payment(%{"amount_cents" => 100})])
    start = start_reporting()
    payment = payment(%{"amount_cents" => 50})

    race(repo, fn index -> submit([if(rem(index, 2) == 0, do: start, else: payment)]) end)

    assert [cash] = report(~D[2026-11-01]).cash
    assert {cash.opening_held_cents, cash.movements.received_cents} in [{100, 50}, {150, 0}]
    assert cash.closing_held_cents == 150
    assert Reservations.ledger().cash_held_cents == 150
    before = snapshot()
    race(repo, fn _ -> submit([start, payment]) end)
    assert snapshot() == before
  end

  test "an audit failure rolls back inception and every cancellation reporting effect" do
    submit([open_group(), payment()])
    start = start_reporting(%{"operation_id" => "fault"})
    fail_audit()
    before = snapshot()
    assert_raise Exqlite.Error, fn -> submit([start]) end
    assert snapshot() == before
    assert Finance.daily_report(~D[2026-11-01]) == {:error, :report_not_available}
    Repo.query!("DROP TRIGGER reject_finance_audit")
    submit([start])

    before = snapshot()
    reports = reports()
    fail_audit()
    cancel = cancellation(%{"operation_id" => "cancel-fault", "refund_method" => "hotel_credit"})
    assert_raise Exqlite.Error, fn -> submit([cancel]) end
    assert snapshot() == before
    assert reports() == reports
    assert Reservations.get_operation_result("cancel-fault") == nil
    Repo.query!("DROP TRIGGER reject_finance_audit")

    assert [%{"credit_issued_cents" => 5500}] = submit([cancel])
    assert report(~D[2026-11-01]).credit.movements.issued_cents == 5500
    assert report(~D[2027-11-02]).credit.movements.expired_cents == 5500
  end

  test "reporting storage failure rolls back its operation, preserving earlier batch commits" do
    submit([open_group(), start_reporting()])

    Repo.query!("""
    CREATE TRIGGER reject_finance_entry BEFORE INSERT ON finance_entries
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'forced finance storage failure'); END
    """)

    operations = [
      payment(%{"operation_id" => "before", "amount_cents" => 20}),
      payment(%{"operation_id" => "fault", "amount_cents" => 30}),
      payment(%{"operation_id" => "after", "amount_cents" => 40})
    ]

    assert_raise Exqlite.Error, ~r/forced finance storage failure/, fn -> submit(operations) end
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 20
    assert Reservations.get_operation_result("fault") == nil
    assert Reservations.get_operation_result("after") == nil
    assert [cash] = report(~D[2026-11-01]).cash
    assert cash.movements.received_cents == 20
    assert cash.closing_held_cents == 20
    Repo.query!("DROP TRIGGER reject_finance_entry")
    assert Enum.all?(submit(operations), &(&1["status"] == "applied"))
    assert [cash] = report(~D[2026-11-01]).cash
    assert cash.movements.received_cents == 90
    assert cash.closing_held_cents == 90
  end

  test "upgrading the previous release preserves legacy balances and starts only on request" do
    submit([
      open_group(%{"group_id" => "seed"}),
      payment(%{"group_id" => "seed"}),
      cancellation(%{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open_group(),
      payment(%{"operation_id" => "legacy-payment"}),
      credit_application(%{"amount_cents" => 500}),
      open_group(%{"group_id" => "destination", "property_id" => "other"}),
      transfer(%{"amount_cents" => 1000})
    ])

    # Legacy payment identity is absent, while its held allocations still form
    # part of the property's opening balance.
    Repo.delete_all(from r in OperationRecord, where: r.operation_id == "legacy-payment")

    Repo.update_all(from(a in CashAllocation, where: a.payment_operation_id == "legacy-payment"),
      set: [payment_operation_id: nil]
    )

    before = domain_snapshot()

    assert Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_005, log: false) == [
             20_260_907_000_005
           ]

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [20_260_907_000_005]
    assert domain_snapshot() == before
    assert Repo.all(Entry) == []
    assert Finance.daily_report(~D[2026-11-01]) == {:error, :report_not_available}
    submit([start_reporting()])

    report = report(~D[2026-11-01])

    assert Enum.map(report.cash, &{&1.property_id, &1.opening_held_cents}) == [
             {"ams-canal", 4500},
             {"other", 500}
           ]

    assert report.credit.opening_liability_cents == 5500
    assert Enum.all?(report.credit.movements, fn {_, cents} -> cents == 0 end)
    assert domain_snapshot() |> Enum.drop(-1) == Enum.drop(before, -1)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  test "batched and sequential submissions produce equivalent reports and survive repository restart",
       %{template: template, database: database, options: options} do
    operations = [
      open_group(),
      payment(%{"operation_id" => "payment", "amount_cents" => 1000}),
      start_reporting(),
      open_group(%{"group_id" => "destination", "property_id" => "other"}),
      transfer(%{"amount_cents" => 300}),
      cancellation(%{
        "group_id" => "destination",
        "occurred_on" => "2026-11-03",
        "refund_method" => "hotel_credit"
      }),
      credit_application(%{"amount_cents" => 200, "occurred_on" => "2026-11-02"}),
      reduction(%{"amount_cents" => 50}),
      chargeback(%{"occurred_on" => "2026-11-04"}),
      cancellation(%{"occurred_on" => "2026-11-05"})
    ]

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

    sequential_database = Path.join(Path.dirname(database), "sequential.db")
    File.cp!(template, sequential_database)
    sequential_options = Keyword.put(options, :database, sequential_database)

    sequential =
      start_supervised!(Supervisor.child_spec({Repo, sequential_options}, id: :sequential))

    Repo.put_dynamic_repo(sequential)
    assert Enum.flat_map(operations, &submit([&1])) == results
    assert reports() == expected
  end

  test "reporting inception and scheduled expiry survive independent application lifetimes", %{
    database: database
  } do
    directory = Path.dirname(database)
    script = Path.join(directory, "finance_restart.exs")
    input = Path.join(directory, "finance_operations.json")
    output = Path.join(directory, "finance_results.json")

    operations = [
      open_group(),
      payment(),
      start_reporting(),
      cancellation(%{"refund_method" => "hotel_credit"})
    ]

    File.write!(input, Jason.encode!(operations))

    File.write!(script, """
    [input, output] = System.argv()
    results = input |> File.read!() |> Jason.decode!() |> GroupStay.Reservations.submit_batch()
    reports = for date <- [~D[2026-11-01], ~D[2027-11-02]] do
      {:ok, report} = GroupStay.Finance.daily_report(date)
      report
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
    assert Enum.at(result["reports"], 1)["credit"]["movements"]["expired_cents"] == 5500
  end

  test "a failed transfer or correction rolls back its reporting and successful retries post once" do
    submit([
      open_group(),
      open_group(%{"group_id" => "destination", "property_id" => "other"}),
      payment(%{"operation_id" => "payment", "amount_cents" => 1000}),
      start_reporting()
    ])

    for operation <- [transfer(%{"amount_cents" => 500}), reduction(), chargeback()] do
      fault = Map.put(operation, "operation_id", "fault")
      before = snapshot()
      fail_audit()
      assert_raise Exqlite.Error, fn -> submit([fault]) end
      assert snapshot() == before
      Repo.query!("DROP TRIGGER reject_finance_audit")

      assert [%{"status" => "applied"}] = result = submit([operation])
      before = snapshot()
      assert submit([operation]) == result

      assert [%{"code" => "operation_id_conflict"}] =
               submit([Map.put(operation, "occurred_on", "2026-11-02")])

      assert snapshot() == before
    end

    assert Enum.sum(Enum.map(report(~D[2026-11-01]).cash, & &1.closing_held_cents)) == 0
  end

  test "downgrades cannot discard a durable inception while retaining its replay result" do
    submit([open_group(), payment(), start_reporting()])
    before = snapshot()

    assert_raise Ecto.MigrationError, ~r/cannot remove finance reporting after inception/, fn ->
      Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_005, log: false)
    end

    assert snapshot() == before
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  defp submit(operations), do: Reservations.submit_batch(operations)

  defp report(date) do
    assert {:ok, report} = Finance.daily_report(date)
    report
  end

  defp reports,
    do:
      Enum.map(
        [
          ~D[2026-11-01],
          ~D[2026-11-02],
          ~D[2026-11-03],
          ~D[2026-11-04],
          ~D[2026-11-05],
          ~D[2027-11-02],
          ~D[2027-11-04]
        ],
        &report/1
      )

  defp snapshot, do: domain_snapshot() ++ [Repo.all(ReportingStart), Repo.all(Entry)]

  defp domain_snapshot,
    do:
      Enum.map(
        [
          Group,
          CashEntry,
          CashAllocation,
          CreditLot,
          CreditAllocation,
          RoomCreditAllocation,
          CreditEntitlement,
          OperationRecord
        ],
        &Repo.all/1
      )

  defp fail_audit do
    Repo.query!("""
    CREATE TRIGGER reject_finance_audit BEFORE INSERT ON operation_records
    WHEN NEW.operation_id IN ('fault', 'cancel-fault')
    BEGIN SELECT RAISE(ABORT, 'forced finance audit failure'); END
    """)
  end
end
