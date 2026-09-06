defmodule GroupStay.DurableOperationsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Phoenix.ConnTest
  alias GroupStay.{Group, Operation, Repo, Reservations}
  @endpoint GroupStayWeb.Endpoint

  setup do
    path = Path.expand("durable-test-#{System.unique_integer([:positive])}.db")

    opts = [
      name: __MODULE__.Repo,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 50
    ]

    start_supervised!({Repo, Keyword.put(opts, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(__MODULE__.Repo)
    Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up, all: true, log: false)

    stop_supervised!(Repo)
    start_supervised!({Repo, opts})

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    %{opts: opts}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 15000},
        %{"room_id" => "b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp op(id, type, fields) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "occurred_on" => "2026-11-26", "group_id" => "g"},
      fields
    )
  end

  defp submit(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "retries preserve all results and accounting, including credit issuance and redemption" do
    operations = [
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100}),
      op("move", "reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      op("cancel", "cancel_group", %{"refund_method" => "hotel_credit"}),
      Map.merge(opening(), %{"operation_id" => "open-next", "group_id" => "next"}),
      op("credit", "apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 100})
    ]

    results = submit(operations)
    totals = Reservations.ledger(~D[2026-11-26])
    assert submit(operations) == results
    assert Reservations.ledger(~D[2026-11-26]) == totals
    assert Repo.get!(Group, "g").revision == 4
    assert Repo.get!(Group, "next").revision == 2
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1

    for {operation, result} <- Enum.zip(operations, results) do
      assert build_conn()
             |> get("/api/v1/operations/#{operation["operation_id"]}")
             |> json_response(200) == %{"data" => result}
    end

    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.submission) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    Repo.query!("ALTER TABLE credit_lots RENAME TO unavailable_lots")
    assert submit(operations) == results
  end

  test "rejected attempts stay rejected, conflicts do not replace records and batches continue" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 10})
    [original, _, retry] = submit([missing, opening(), missing])
    assert original == retry
    assert original["code"] == "group_not_found"
    stale = op("stale", "record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 0})

    [rejected, _, retried, conflict] =
      submit([
        stale,
        op("pay", "record_cash_payment", %{"amount_cents" => 10}),
        stale,
        Map.put(stale, "expected_revision", 2)
      ])

    assert rejected == retried
    assert rejected["actual_revision"] == 1
    assert conflict["code"] == "operation_id_conflict"
    assert Reservations.get_operation("stale") == rejected
    assert Repo.get!(Group, "g").revision == 2

    invalid = %{
      "operation_id" => "invalid",
      "type" => ["unknown"],
      "extra" => %{"a" => [1, nil, true]}
    }

    [result, repeated] = submit([invalid, invalid])
    assert result == repeated
    assert Repo.get_by!(Operation, operation_id: "invalid").submission == invalid

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "object order is immaterial but arrays, extra fields and value types are significant" do
    payload = Jason.encode!(opening())

    reversed =
      "{" <>
        (opening()
         |> Enum.reverse()
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end)) <>
        "}"

    send_json = fn body ->
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", "{\"operations\":[" <> body <> "]}")
      |> json_response(200)
    end

    assert send_json.(payload) == send_json.(reversed)

    for changed <- [
          Map.update!(opening(), "rooms", &Enum.reverse/1),
          Map.put(opening(), "extra", nil),
          put_in(opening(), ["rooms", Access.at(0), "nightly_rate_cents"], 15000.0)
        ] do
      assert [%{"code" => "operation_id_conflict"}] = submit([changed])
    end

    assert Repo.aggregate(Operation, :count) == 1
  end

  @tag capture_log: true
  test "concurrent retries commit once and remain readable after repository restart", %{
    opts: opts
  } do
    [opened] = submit([opening()])
    payment = op("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(__MODULE__.Repo)
          retry_locked_payment(payment, 30)
        end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(Enum.uniq(results)) == 1
    assert [[%{"status" => "applied", "revision" => 2}]] = Enum.uniq(results)
    assert Repo.get!(Group, "g").cash_paid_cents == 100
    assert Repo.aggregate(Operation, :count) == 2
    rejected = op("rejected", "cancel_group", %{"expected_revision" => 0})
    [rejection] = submit([rejected])
    order = Repo.all(from o in Operation, order_by: o.id, select: {o.id, o.operation_id})
    stop_supervised!(Repo)
    start_supervised!({Repo, opts})
    assert submit([rejected]) == [rejection]
    assert Repo.all(from o in Operation, order_by: o.id, select: {o.id, o.operation_id}) == order
    assert submit([opening()]) == [opened]
    assert submit([payment]) == hd(results)
    assert Repo.get!(Group, "g").revision == 2
  end

  test "room settlements and payment corrections survive restart and roll back audit faults", %{
    opts: opts
  } do
    pay = op("pay", "record_cash_payment", %{"amount_cents" => 15000})
    [_, original] = submit([opening(), pay])

    cancel =
      op("partial", "cancel_rooms", %{"room_ids" => ["b"], "refund_method" => "hotel_credit"})

    reduce =
      op("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 1000
      })

    results = submit([cancel, reduce])
    assert Enum.all?(results, &(&1["status"] == "applied"))

    charge =
      op("charge", "charge_back_payment", %{
        "payment_operation_id" => "pay",
        "expected_revision" => 4
      })

    before_group = Reservations.get_group("g")
    before_ledger = Reservations.ledger(~D[2026-11-26])

    Repo.query!("""
    CREATE TRIGGER fail_charge BEFORE INSERT ON operations WHEN NEW.operation_id = 'charge'
    BEGIN SELECT RAISE(ABORT, 'injected chargeback audit failure'); END
    """)

    assert_error_sent 500, fn -> submit([charge]) end
    assert Reservations.get_group("g") == before_group
    assert Reservations.ledger(~D[2026-11-26]) == before_ledger
    assert Reservations.get_operation("charge") == nil
    Repo.query!("DROP TRIGGER fail_charge")

    concurrent =
      1..6
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(__MODULE__.Repo)
          retry_locked_payment(charge, 30)
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [[charged]] = Enum.uniq(concurrent)
    assert charged["charged_back_cents"] == 14000
    {:ok, statement} = Reservations.get_payment("pay")
    stop_supervised!(Repo)
    start_supervised!({Repo, opts})
    assert submit([pay, cancel, reduce, charge]) == [original | results] ++ [charged]
    assert Reservations.get_payment("pay") == {:ok, statement}
    assert Reservations.get_group("g").revision == 5
    assert [%{"code" => "operation_id_conflict"}] = submit([Map.put(reduce, "amount_cents", 2)])
  end

  @tag capture_log: true
  test "transfers commit both groups once, roll back write faults and survive restart", %{
    opts: opts
  } do
    destination = Map.merge(opening(), %{"operation_id" => "open-next", "group_id" => "next"})
    pay = op("pay", "record_cash_payment", %{"amount_cents" => 100})
    submit([opening(), destination, pay])

    transfer =
      op("transfer", "transfer_deposit", %{
        "source_group_id" => "g",
        "destination_group_id" => "next",
        "amount_cents" => 100,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    before = Repo.all(Group)

    for {name, trigger} <- [
          {"fail_transfer_domain", "BEFORE UPDATE ON groups WHEN NEW.group_id = 'next'"},
          {"fail_transfer_audit",
           "BEFORE INSERT ON operations WHEN NEW.operation_id = 'transfer'"}
        ] do
      Repo.query!(
        "CREATE TRIGGER #{name} #{trigger} BEGIN SELECT RAISE(ABORT, 'injected transfer failure'); END"
      )

      assert_error_sent 500, fn -> submit([transfer]) end
      assert Repo.all(Group) == before
      assert Reservations.get_operation("transfer") == nil
      Repo.query!("DROP TRIGGER #{name}")
    end

    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(__MODULE__.Repo)
          retry_locked_payment(transfer, 30)
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [[result]] = Enum.uniq(results)
    assert result["source_revision"] == 3
    assert result["destination_revision"] == 2
    stop_supervised!(Repo)
    start_supervised!({Repo, opts})
    assert submit([transfer]) == [result]

    assert {:ok, %{"held_by_group" => [%{"group_id" => "next", "amount_cents" => 100}]}} =
             Reservations.get_payment("pay")

    reduction =
      op("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 40,
        "expected_revision" => 3
      })

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 19500}] = submit([reduction])
    assert Reservations.get_group("next").revision == 3
    assert Reservations.get_group("next").cash_paid_cents == 60

    charge =
      op("charge", "charge_back_payment", %{
        "payment_operation_id" => "pay",
        "expected_revision" => 4
      })

    assert [%{"revision" => 5, "charged_back_cents" => 60}] = submit([charge])
    assert Reservations.get_group("next").revision == 4
    assert {:ok, %{"held_by_group" => []}} = Reservations.get_payment("pay")
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert submit([transfer]) == [result]
  end

  @tag capture_log: true
  test "finance inception and movements commit once, roll back faults and survive restart", %{
    opts: opts
  } do
    submit([opening()])
    inception = op("finance-start", "start_finance_reporting", %{"starts_on" => "2026-11-26"})

    Repo.query!(
      "CREATE TRIGGER fail_start BEFORE INSERT ON operations WHEN NEW.operation_id = 'finance-start' BEGIN SELECT RAISE(ABORT, 'injected inception failure'); END"
    )

    assert_error_sent 500, fn -> submit([inception]) end
    assert Repo.aggregate(GroupStay.Finance.Start, :count) == 0
    assert Reservations.get_operation("finance-start") == nil
    Repo.query!("DROP TRIGGER fail_start")
    [started] = submit([inception])
    payment = op("finance-pay", "record_cash_payment", %{"amount_cents" => 100})

    for {name, trigger} <- [
          {"fail_journal", "BEFORE INSERT ON finance_entries"},
          {"fail_finance_audit",
           "BEFORE INSERT ON operations WHEN NEW.operation_id = 'finance-pay'"}
        ] do
      Repo.query!(
        "CREATE TRIGGER #{name} #{trigger} BEGIN SELECT RAISE(ABORT, 'injected reporting failure'); END"
      )

      assert_error_sent 500, fn -> submit([payment]) end
      assert Reservations.get_group("g").cash_paid_cents == 0
      assert Repo.aggregate(GroupStay.Finance.Entry, :count) == 0
      assert Reservations.get_operation("finance-pay") == nil
      Repo.query!("DROP TRIGGER #{name}")
    end

    concurrent =
      1..6
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(__MODULE__.Repo)
          retry_locked_payment(payment, 30)
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [[paid]] = Enum.uniq(concurrent)
    assert Repo.aggregate(GroupStay.Finance.Entry, :count) == 1
    report = GroupStay.Finance.daily("2026-11-26")
    assert {:ok, %{cash: [%{closing_held_cents: 100}]}} = report
    stop_supervised!(Repo)
    start_supervised!({Repo, opts})
    assert GroupStay.Finance.daily("2026-11-26") == report
    assert submit([inception, payment]) == [started, paid]
    assert Repo.aggregate(GroupStay.Finance.Entry, :count) == 1
    Repo.query!("ALTER TABLE finance_reporting RENAME TO unavailable_reporting")
    Repo.query!("ALTER TABLE finance_entries RENAME TO unavailable_entries")
    assert submit([inception, payment]) == [started, paid]
  end

  # A contending SQLite connection may time out acquiring the writer. Like the
  # gateway, retry that server fault; only a committed result can be replayed.
  defp retry_locked_payment(payment, attempts) do
    Reservations.batch([payment])
  rescue
    error in Exqlite.Error ->
      if attempts > 0 and error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message == "database is locked" do
        retry_locked_payment(payment, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  for stage <- [:domain, :audit] do
    test "unexpected #{stage} faults roll back effects and audit record, abort the request, and allow retry" do
      submit([opening()])

      trigger =
        case unquote(stage) do
          :domain -> "BEFORE UPDATE ON groups WHEN NEW.status = 'cancelled'"
          :audit -> "BEFORE INSERT ON operations WHEN NEW.operation_id = 'broken'"
        end

      Repo.query!("""
      CREATE TRIGGER fail_audit #{trigger}
      BEGIN SELECT RAISE(ABORT, 'injected write failure'); END
      """)

      earlier = op("earlier", "record_cash_payment", %{"amount_cents" => 10})
      broken = op("broken", "cancel_group", %{"refund_method" => "hotel_credit"})
      later = Map.put(opening(), "operation_id", "later")
      assert_error_sent 500, fn -> submit([earlier, broken, later]) end
      assert Repo.get!(Group, "g").revision == 2
      assert Repo.get!(Group, "g").status == "active"
      assert Repo.aggregate(GroupStay.CreditLot, :count) == 0
      assert Reservations.get_operation("broken") == nil
      assert Reservations.get_operation("later") == nil
      Repo.query!("DROP TRIGGER fail_audit")

      assert [%{"revision" => 2}, %{"revision" => 3}, %{"code" => "group_already_exists"}] =
               submit([earlier, broken, later])

      assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
    end
  end
end
