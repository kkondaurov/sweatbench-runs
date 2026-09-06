defmodule GroupStay.DurableOperationsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  import Ecto.Query
  alias GroupStay.{Repo, Reservations, Operation, Group, CreditLot, CreditAllocation}
  @endpoint GroupStayWeb.Endpoint

  defmodule DurableRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    migrations =
      for path <- Path.wildcard(Application.app_dir(:group_stay, "priv/repo/migrations/*.exs")) do
        [{module, _}] = Code.compile_file(path)
        {version, _} = Integer.parse(Path.basename(path))
        {version, module}
      end

    {:ok, migrations: migrations}
  end

  setup %{migrations: migrations} do
    path = Path.expand("tmp/durable-#{System.unique_integer([:positive])}.db")
    # Initialize WAL and migrate with one connection before starting competing clients.
    start_supervised!({DurableRepo, database: path, pool_size: 1})
    Ecto.Migrator.run(DurableRepo, migrations, :up, all: true, log: false)
    :ok = stop_supervised(DurableRepo)
    start_supervised!({DurableRepo, database: path, pool_size: 8})
    previous = Repo.put_dynamic_repo(DurableRepo)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    {:ok, path: path}
  end

  defp op(id, type, attrs) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-01-01"
      },
      attrs
    )
  end

  defp opening(id \\ "open", attrs \\ %{}) do
    op(
      id,
      "open_group",
      Map.merge(
        %{
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "a", "nightly_rate_cents" => 10000},
            %{"room_id" => "b", "nightly_rate_cents" => 20000}
          ]
        },
        attrs
      )
    )
  end

  defp batch(ops) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: ops}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(id) do
    build_conn() |> get("/api/v1/operations/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot do
    Enum.map(
      [Group, CreditLot, CreditAllocation, Operation, "room_accounts", "lot_clawbacks"],
      fn schema ->
        case schema do
          "room_accounts" ->
            Repo.all(from row in schema, order_by: row.group_id, select: {row.group_id, row.data})

          "lot_clawbacks" ->
            Repo.all(from row in schema, order_by: row.lot_id, select: {row.lot_id, row.amount})

          _ ->
            Repo.all(from row in schema, order_by: fragment("1"))
        end
      end
    )
  end

  test "whole batch retries preserve every result and all cash and credit effects" do
    operations = [
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100}),
      op("move", "reschedule_group", %{"new_arrival_on" => "2027-07-01"}),
      op("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target", %{"group_id" => "target"}),
      op("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      op("restore", "cancel_group", %{"group_id" => "target"})
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4, 1, 2, 3]
    before = snapshot()
    assert batch(operations ++ operations) == results ++ results
    assert snapshot() == before
    assert Enum.map(operations, &read(&1["operation_id"])) == results
    assert Reservations.ledger(~D[2027-01-01]).cash_converted_to_credit_cents == 100
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 110
    records = Repo.all(from o in Operation, order_by: o.id)
    assert Enum.map(records, & &1.payload) == operations
    assert Enum.map(records, & &1.type) == Enum.map(operations, & &1["type"])
    assert Enum.map(records, & &1.result) == results
  end

  test "JSON key order is irrelevant while arrays, types, missing keys and extra content matter" do
    original = opening("opaque ID:α", %{"extra" => %{"b" => [1, true, nil], "a" => "value"}})
    [result] = batch([original])
    # Encode an explicitly reordered object, including nested room and metadata keys.
    reordered =
      Jason.OrderedObject.new(
        Enum.reverse(
          Enum.map(original, fn
            {"rooms", rooms} ->
              {"rooms", Enum.map(rooms, &Jason.OrderedObject.new(Enum.reverse(Map.to_list(&1))))}

            {"extra", extra} ->
              {"extra", Jason.OrderedObject.new(Enum.reverse(Map.to_list(extra)))}

            pair ->
              pair
          end)
        )
      )

    assert batch([reordered]) == [result]

    variants = [
      Map.put(original, "rooms", Enum.reverse(original["rooms"])),
      put_in(original, ["rooms", Access.at(0), "nightly_rate_cents"], 10000.0),
      Map.put(original, "extra", nil),
      Map.delete(original, "extra"),
      Map.put(original, "expected_revision", nil),
      Map.put(original, "type", "cancel_group"),
      Map.put(original, "group_id", "different")
    ]

    before = snapshot()

    for variant <- variants do
      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] = batch([variant])
    end

    assert snapshot() == before
    assert batch([original]) == [result]
  end

  test "rejected attempts and stale details survive domain changes and corrected retries conflict" do
    missing = op("missing", "record_cash_payment", %{"amount_cents" => 10})
    invalid = op("invalid", "unknown", %{"metadata" => [nil, %{"x" => false}]})
    [missing_result, invalid_result, _] = batch([missing, invalid, opening()])
    assert missing_result["code"] == "group_not_found"
    assert invalid_result["code"] == "invalid_operation"
    stale = op("stale", "cancel_group", %{"expected_revision" => 0})
    [stale_result, _] = batch([stale, op("pay", "record_cash_payment", %{"amount_cents" => 10})])
    assert stale_result["actual_revision"] == 1
    before = snapshot()
    assert batch([missing, invalid, stale]) == [missing_result, invalid_result, stale_result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 2)])

    assert snapshot() == before

    for result <- [missing_result, invalid_result, stale_result],
        do: assert(read(result["operation_id"]) == result)

    assert batch([op("cancel", "cancel_group", %{"expected_revision" => 2})])
           |> hd()
           |> Map.fetch!("revision") == 3
  end

  test "exact retries never consult domain tables" do
    operations = [opening(), op("stale", "cancel_group", %{"expected_revision" => 0})]
    results = batch(operations)
    sql("DROP TABLE credit_allocations")
    sql("DROP TABLE credit_lots")
    sql("DROP TABLE groups")
    assert batch(operations) == results
    assert Enum.map(operations, &read(&1["operation_id"])) == results
  end

  test "malformed identifiable operations are audited; unusable identifiers still reject" do
    for {type, index} <- Enum.with_index([nil, 1, [], %{}]) do
      malformed = %{"operation_id" => "bad-#{index}", "type" => type}
      [result] = batch([malformed])
      assert result["code"] == "invalid_operation"
      assert batch([malformed]) == [result]
      assert Repo.get_by!(Operation, operation_id: "bad-#{index}").payload == malformed
    end

    assert Enum.all?(
             batch([nil, [], %{}, %{"operation_id" => ""}, %{"operation_id" => 1}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Operation, :count) == 4

    assert build_conn() |> get("/api/v1/operations/absent") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  @tag capture_log: true
  test "concurrent identical requests and conflicting payloads use independent database connections" do
    [opened] = batch([opening()])
    payment = op("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    results = concurrent(List.duplicate(payment, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 2
    assert Reservations.get_group("group").cash_paid_cents == 100

    contenders =
      for amount <- 1..8, do: op("race", "record_cash_payment", %{"amount_cents" => amount})

    results = concurrent(contenders)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 7
    winner = Enum.find(results, &(&1.status == "applied"))
    assert Reservations.get_group("group").cash_paid_cents == 100 + winner.amount_cents
    assert Repo.aggregate(Operation, :count) == 3
    assert read("open") == opened
  end

  defp concurrent(operations) do
    operations
    |> Task.async_stream(
      fn operation ->
        Repo.put_dynamic_repo(DurableRepo)
        [result] = Reservations.batch([operation])
        result
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "application and database restarts retain results, submissions and first commit order", %{
    path: path
  } do
    operations = [
      opening(),
      op("rejected", "cancel_group", %{"expected_revision" => 9}),
      op("pay", "record_cash_payment", %{"amount_cents" => 50})
    ]

    results = batch(operations)
    before = snapshot()
    :ok = stop_supervised(DurableRepo)
    fixture = path <> ".json"
    script = path <> ".exs"
    File.write!(fixture, Jason.encode!(%{operations: operations, results: results}))

    File.write!(script, """
    [fixture] = System.argv()
    %{"operations" => operations, "results" => expected} = fixture |> File.read!() |> Jason.decode!()
    for _ <- 1..2 do
      {:ok, _} = Application.ensure_all_started(:group_stay)
      actual = GroupStay.Reservations.batch(operations) |> Jason.encode!() |> Jason.decode!()
      if actual != expected, do: raise("retry changed after restart")
      for result <- expected do
        if GroupStay.Reservations.get_operation(result["operation_id"]) != result,
          do: raise("stored result changed after restart")
      end
      :ok = Application.stop(:group_stay)
    end
    """)

    on_exit(fn ->
      File.rm(fixture)
      File.rm(script)
    end)

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-start", script, fixture],
        env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", path}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    start_supervised!({DurableRepo, database: path, pool_size: 8})
    assert batch(operations) == results
    assert snapshot() == before
    assert Enum.map(operations, &read(&1["operation_id"])) == results
  end

  test "unexpected audit failure rolls back domain writes, returns 500 and stops the batch" do
    sql("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'issue'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    operations = [
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 100}),
      op("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("later", %{"group_id" => "later"})
    ]

    assert_error_sent 500, fn -> batch(operations) end
    assert Reservations.get_group("group").revision == 2
    assert Reservations.get_group("group").status == "active"
    assert Repo.all(CreditLot) == []
    assert Reservations.get_operation("issue") == nil
    assert Reservations.get_operation("later") == nil
    assert Reservations.get_group("later") == nil
    assert Repo.aggregate(Operation, :count) == 2
    sql("DROP TRIGGER fail_audit")
    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert Reservations.get_group("group").cash_paid_cents == 0
    assert Reservations.guest_credit("guest", ~D[2027-01-01]).available_cents == 110
    assert batch(operations) == results
  end

  test "concurrent reductions and chargebacks have at-most-once effects" do
    batch([opening(), op("pay", "record_cash_payment", %{"amount_cents" => 300})])

    reduction =
      op("reduce", "reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 50})

    results = concurrent(List.duplicate(reduction, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 3
    charge = op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    results = concurrent(List.duplicate(charge, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).charged_back_cents == 250
    assert hd(results).revision == 4

    assert {:ok, %{held_cents: 0, reduced_cents: 50, charged_back_cents: 250}} =
             Reservations.get_payment("pay")
  end

  test "room settlements, clawbacks, statements and retries survive a database restart", %{
    path: path
  } do
    operations = [
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 3000}),
      op("cancel-a", "cancel_rooms", %{"room_ids" => ["a"], "refund_method" => "hotel_credit"}),
      opening("destination", %{"group_id" => "destination"}),
      op("redeem", "apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 2100}),
      op("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 100
      }),
      op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = snapshot()
    statement = Reservations.get_payment("pay")
    ledger = Reservations.ledger(~D[2027-01-01])
    assert ledger.credit_shortfall_cents == 2100
    :ok = stop_supervised(DurableRepo)
    start_supervised!({DurableRepo, database: path, pool_size: 8})
    assert batch(operations) == results
    assert snapshot() == before
    assert Reservations.get_payment("pay") == statement
    assert Reservations.ledger(~D[2027-01-01]) == ledger
  end

  test "a failed chargeback audit rolls back cash, credit entitlement and room changes" do
    batch([
      opening(),
      op("pay", "record_cash_payment", %{"amount_cents" => 3000}),
      op("cancel", "cancel_rooms", %{"room_ids" => ["a"], "refund_method" => "hotel_credit"})
    ])

    before = snapshot()

    sql(
      "CREATE TRIGGER fail_charge BEFORE INSERT ON operations WHEN NEW.operation_id = 'charge' BEGIN SELECT RAISE(ABORT, 'audit failure'); END"
    )

    charge = op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    assert_error_sent 500, fn -> batch([charge]) end
    assert snapshot() == before
    sql("DROP TRIGGER fail_charge")
    assert [%{"charged_back_cents" => 3000, "revision" => 4}] = batch([charge])
  end

  test "finance inception and movements are atomic, concurrent and durable", %{path: path} do
    batch([opening(), op("pay", "record_cash_payment", %{"amount_cents" => 100})])
    start = op("finance-start", "start_finance_reporting", %{"starts_on" => "2027-01-01"})

    sql(
      "CREATE TRIGGER fail_start BEFORE INSERT ON operations WHEN NEW.operation_id = 'finance-start' BEGIN SELECT RAISE(ABORT, 'audit failure'); END"
    )

    assert_error_sent 500, fn -> batch([start]) end
    assert GroupStay.Finance.inception() == nil
    sql("DROP TRIGGER fail_start")
    starts = concurrent(List.duplicate(start, 8))
    assert length(Enum.uniq(starts)) == 1
    assert hd(starts).status == "applied"
    payment = op("finance-pay", "record_cash_payment", %{"amount_cents" => 50})
    assert concurrent(List.duplicate(payment, 8)) |> Enum.uniq() |> length() == 1
    {:ok, before} = GroupStay.Finance.daily("2027-01-01")
    assert hd(before.cash).opening_held_cents == 100
    assert hd(before.cash).movements["received_cents"] == 50

    sql(
      "CREATE TRIGGER fail_finance BEFORE INSERT ON finance_movements BEGIN SELECT RAISE(ABORT, 'report failure'); END"
    )

    issue = op("finance-issue", "cancel_group", %{"refund_method" => "hotel_credit"})
    assert_error_sent 500, fn -> batch([issue]) end
    assert Reservations.get_operation("finance-issue") == nil
    assert Reservations.get_group("group").cash_paid_cents == 150
    assert Repo.all(CreditLot) == []
    assert GroupStay.Finance.daily("2027-01-01") == {:ok, before}
    sql("DROP TRIGGER fail_finance")
    batch([issue])
    reports = Enum.map(~w(2027-01-01 2028-01-02), &GroupStay.Finance.daily/1)
    :ok = stop_supervised(DurableRepo)
    start_supervised!({DurableRepo, database: path, pool_size: 8})
    batch([start, payment, issue])
    assert Enum.map(~w(2027-01-01 2028-01-02), &GroupStay.Finance.daily/1) == reports

    assert [%{status: "rejected", code: "reporting_already_started"}] =
             Reservations.batch([Map.put(start, "operation_id", "another-start")])
  end

  test "period close is atomic with its audit record and serializes competing cutoffs" do
    batch([op("start", "start_finance_reporting", %{"starts_on" => "2027-01-01"})])
    close = op("close", "close_finance_period", %{"period_end_on" => "2027-01-01"})

    sql(
      "CREATE TRIGGER fail_close BEFORE INSERT ON operations WHEN NEW.operation_id = 'close' BEGIN SELECT RAISE(ABORT, 'audit failure'); END"
    )

    assert_error_sent 500, fn -> batch([close]) end
    assert Reservations.get_operation("close") == nil
    assert GroupStay.Finance.inception().closed_through == nil
    {:ok, report} = GroupStay.Finance.daily("2027-01-01")
    assert report.status == "open"
    sql("DROP TRIGGER fail_close")

    retries = concurrent(List.duplicate(close, 8))
    assert length(Enum.uniq(retries)) == 1
    assert hd(retries).status == "applied"

    competing =
      for i <- 1..8,
          do: %{close | "operation_id" => "next-#{i}", "period_end_on" => "2027-01-02"}

    results = concurrent(competing)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 7
    {:ok, report} = GroupStay.Finance.daily("2027-01-02")
    assert report.status == "closed"
  end

  defp sql(statement), do: Ecto.Adapters.SQL.query!(DurableRepo, statement, [])
end
