defmodule GroupStay.FinanceReportingTest do
  use GroupStay.CommittedCase, async: false

  import GroupStay.PartnerFixtures
  import Phoenix.ConnTest
  import Plug.Conn

  alias GroupStay.{Finance, Operations, Repo}
  alias GroupStay.Finance.Reporting
  alias GroupStay.Finance.Reporting.{Entry, Inception}

  @endpoint GroupStayWeb.Endpoint

  test "upgrading preserves all prior state and captures legacy funding at inception" do
    Operations.apply_batch([
      open_group(%{"group_id" => "issuer"}),
      operation("record_cash_payment", %{"group_id" => "issuer", "amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
      open_group(),
      operation("apply_hotel_credit", %{"amount_cents" => 50}),
      operation("record_cash_payment", %{"amount_cents" => 75}),
      open_group(%{"group_id" => "destination", "property_id" => "other"}),
      transfer_deposit("group-81", "destination", 20)
    ])

    # Model funding without a durable operation identity. Inception must use
    # current balances, including pre-audit funding, instead of replaying records.
    Repo.delete_all(GroupStay.Operations.Record)
    Repo.query!("UPDATE cash_allocations SET payment_operation_id = NULL")
    Repo.query!("UPDATE credit_entitlements SET payment_operation_id = NULL")

    assert [20_260_907_060_000, 20_260_907_050_000] =
             Ecto.Migrator.run(Repo, :down, to: 20_260_907_050_000, log: false)

    before = domain_snapshot()

    assert [20_260_907_050_000, 20_260_907_060_000] =
             Ecto.Migrator.run(Repo, :up, all: true, log: false)

    assert domain_snapshot() == before
    assert Reporting.daily_report(~D[2026-10-03]) == {:error, "report_not_available"}

    assert [%{"status" => "applied"}] = Operations.apply_batch([start_reporting()])
    assert domain_snapshot() == before
    assert {:ok, report} = Reporting.daily_report(~D[2026-10-03])

    assert Enum.map(report.cash, &{&1.property_id, &1.opening_held_cents, &1.closing_held_cents}) ==
             [{"ams-canal", 55, 55}, {"other", 20, 20}]

    assert report.credit.opening_liability_cents == 110
    assert {:ok, expired} = Reporting.daily_report(~D[2027-10-04])
    assert expired.credit.movements["expired_cents"] == 60
    assert expired.credit.closing_liability_cents == 50
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []

    Ecto.Migrator.run(Repo, :down, to: 20_260_907_060_000, log: false)
    before_downgrade = snapshot()

    assert_raise Ecto.MigrationError, ~r/cannot downgrade after finance reporting starts/, fn ->
      Ecto.Migrator.run(Repo, :down, step: 1, log: false)
    end

    assert snapshot() == before_downgrade
  end

  for type <-
        ~w(record_cash_payment apply_hotel_credit cancel_group cancel_rooms transfer_deposit reduce_cash_payment charge_back_payment),
      table <- ~w(finance_reporting_entries operation_records) do
    test "#{type} rolls back reporting and domain state when #{table} fails" do
      setup_funding()
      failed = failing_operation(unquote(type))
      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER fail_reporting BEFORE INSERT ON #{unquote(table)}
      WHEN NEW.operation_id = 'fail'
      BEGIN SELECT RAISE(ABORT, 'injected reporting fault'); END
      """)

      assert_error_sent(500, fn -> post_batch([failed, open_group(%{"group_id" => "later"})]) end)
      assert snapshot() == before
      assert Operations.get_result("fail") == nil
      Repo.query!("DROP TRIGGER fail_reporting")

      assert [%{"status" => "applied"} = result] = Operations.apply_batch([failed])
      after_success = snapshot()
      assert Operations.apply_batch([failed]) == [result]
      assert snapshot() == after_success
      assert {:ok, report} = Reporting.daily_report(~D[2026-10-03])
      totals = Finance.totals(~D[2026-10-03])
      assert report.credit.closing_liability_cents == totals.credit_liability_cents
      assert Enum.sum(Enum.map(report.cash, & &1.closing_held_cents)) == totals.cash_held_cents
    end
  end

  test "failure to remember inception rolls back the opening position and its scheduled expiry" do
    Operations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    before = snapshot()
    start = start_reporting(%{"operation_id" => "fail"})

    Repo.query!("""
    CREATE TRIGGER fail_start BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fail'
    BEGIN SELECT RAISE(ABORT, 'injected inception fault'); END
    """)

    assert_error_sent(500, fn -> post_batch([start]) end)
    assert snapshot() == before
    assert Reporting.daily_report(~D[2026-10-03]) == {:error, "report_not_available"}
    Repo.query!("DROP TRIGGER fail_start")
    assert [%{"status" => "applied"}] = Operations.apply_batch([start])
    assert [%Entry{movements: %{"expired_cents" => 110}}] = Repo.all(Entry)
  end

  test "concurrent starts choose one durable inception and retries never duplicate it", %{
    repo: repo
  } do
    starts = Enum.map(1..6, fn _ -> start_reporting() end)
    results = concurrently(repo, starts)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reporting_already_started")) == 5
    assert Repo.aggregate(Inception, :count) == 1

    winner = Enum.find(results, &(&1["status"] == "applied"))
    start = Enum.find(starts, &(&1["operation_id"] == winner["operation_id"]))
    before = snapshot()
    assert concurrently(repo, List.duplicate(start, 6)) == List.duplicate(winner, 6)
    assert snapshot() == before
  end

  test "concurrent payment retries create one receipt", %{repo: repo} do
    Operations.apply_batch([start_reporting(), open_group()])
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    results = concurrently(repo, List.duplicate(payment, 6))
    assert length(Enum.uniq(results)) == 1
    assert [%Entry{movements: %{"received_cents" => 100}}] = Repo.all(Entry)
  end

  test "equivalent batches and sequential submissions have identical reports" do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      start_reporting(),
      operation("record_cash_payment", %{"amount_cents" => 200, "occurred_on" => "2026-10-05"}),
      operation("cancel_group", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-10-04"
      }),
      open_group(%{"group_id" => "destination"}),
      operation("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 100}),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"group_id" => "destination", "occurred_on" => "2026-10-06"})
    ]

    assert {:error, batched} =
             Repo.transaction(fn ->
               Operations.apply_batch(operations)
               Repo.rollback(reports())
             end)

    Enum.each(operations, &Operations.apply_batch([&1]))
    assert reports() == batched
  end

  test "reports and scheduled expiry survive replacing database processes", %{database: database} do
    setup_funding()
    before = reports()
    stored = snapshot()
    stop_supervised!(Repo)

    repo =
      start_supervised!({Repo, name: nil, database: database, pool: DBConnection.ConnectionPool})

    Repo.put_dynamic_repo(repo)
    assert reports() == before
    assert snapshot() == stored

    # Reporting reads and exact retries need only their durable records.
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert reports() == before

    assert Operations.apply_batch([start_reporting(%{"operation_id" => "start"})]) ==
             [Operations.get_result("start")]
  end

  defp setup_funding do
    results =
      Operations.apply_batch([
        start_reporting(%{"operation_id" => "start"}),
        open_group(%{"group_id" => "issuer"}),
        operation("record_cash_payment", %{
          "group_id" => "issuer",
          "operation_id" => "issuer-pay",
          "amount_cents" => 100
        }),
        operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
        open_group(),
        operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 1000}),
        operation("apply_hotel_credit", %{"amount_cents" => 50}),
        open_group(%{"group_id" => "destination", "property_id" => "other"})
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp failing_operation("transfer_deposit"),
    do: transfer_deposit("group-81", "destination", 100, %{"operation_id" => "fail"})

  defp failing_operation(type),
    do:
      operation(type, %{
        "operation_id" => "fail",
        "amount_cents" => 50,
        "room_ids" => ["room-b"],
        "refund_method" => "hotel_credit",
        "payment_operation_id" =>
          if(type == "charge_back_payment", do: "issuer-pay", else: "payment")
      })

  defp start_reporting(overrides \\ %{}),
    do:
      operation("start_finance_reporting", Map.merge(%{"starts_on" => "2026-10-03"}, overrides))
      |> Map.delete("group_id")

  defp post_batch(operations),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))

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

  defp reports,
    do:
      Enum.map(
        [
          ~D[2026-10-03],
          ~D[2026-10-04],
          ~D[2026-10-05],
          ~D[2026-10-06],
          ~D[2027-10-04],
          ~D[2027-10-07]
        ],
        &Reporting.daily_report/1
      )

  defp snapshot,
    do:
      Map.merge(
        domain_snapshot(),
        Map.new(
          ~w(operation_records finance_reporting_inceptions finance_reporting_entries),
          &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1").rows}
        )
      )

  defp domain_snapshot,
    do:
      Map.new(
        ~w(groups rooms cash_entries cash_allocations credit_lots credit_allocations credit_entitlements),
        &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1").rows}
      )
end
