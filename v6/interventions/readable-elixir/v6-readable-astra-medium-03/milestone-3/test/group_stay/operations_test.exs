defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.Group

  @endpoint GroupStayWeb.Endpoint

  setup do
    directory = Path.expand("tmp/operations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "test.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1,
      busy_timeout: 2_000
    ]

    repo = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up, all: true, log: false)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GroupStay.TestDatabase.remove!(directory)
    end)

    %{repo: repo, options: options}
  end

  defp opening(id \\ "open", group \\ "group") do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "group_id" => group,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2026-10-01",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-03",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 1000},
        %{"room_id" => "b", "nightly_rate_cents" => 1000}
      ]
    }
  end

  defp operation(id, type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2026-10-02"
      },
      attrs
    )
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "retries preserve exact results through later state changes and expose only results" do
    open = opening()
    pay = operation("pay", "record_cash_payment", %{"amount_cents" => 100})
    stale = operation("stale", "cancel_group", %{"expected_revision" => 1})
    move = operation("move", "reschedule_group", %{"new_arrival_on" => "2027-01-01"})
    cancel = operation("cancel", "cancel_group", %{"refund_method" => "hotel_credit"})
    operations = [open, pay, stale, move, cancel]
    results = batch(operations)
    assert Enum.at(results, 2)["actual_revision"] == 2
    assert List.last(results)["credit_issued_cents"] == 110
    totals = Reservations.ledger(~D[2026-10-02])
    assert batch(operations) == results
    assert Reservations.ledger(~D[2026-10-02]) == totals
    assert Repo.get!(Group, "group").revision == 4
    assert Repo.aggregate(GroupStay.HotelCredit.Lot, :count) == 1

    for {op, result} <- Enum.zip(operations, results) do
      assert build_conn() |> get("/api/v1/operations/#{op["operation_id"]}") |> json_response(200) ==
               %{"data" => result}
    end

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(stale, "expected_revision", 4)])

    assert Operations.get_result("stale") == Enum.at(results, 2)
  end

  test "rejections remain remembered when later operations make them valid" do
    pay = operation("pay", "record_cash_payment", %{"amount_cents" => 10})
    [rejected, _, retry] = batch([pay, opening(), pay])
    assert rejected["code"] == "group_not_found"
    assert retry == rejected
    assert Repo.get!(Group, "group").revision == 1
    invalid = %{"operation_id" => "unknown", "type" => ["future"], "extra" => %{"x" => nil}}
    assert [result, retry] = batch([invalid, invalid])
    assert retry == result
    assert result["code"] == "invalid_operation"
    assert Repo.get_by!(Record, operation_id: "unknown").submission == invalid

    assert Enum.all?(
             batch([nil, %{}, %{"operation_id" => ""}]),
             &(&1["code"] == "invalid_operation")
           )

    assert Repo.aggregate(Record, :count) == 3
  end

  test "JSON object order is irrelevant, while array order, values and extra fields matter" do
    op = Map.put(opening(), "metadata", %{"b" => [1, true, nil], "a" => %{"z" => "x"}})
    [result] = batch([op])

    reordered =
      Enum.map_join(Enum.reverse(Enum.to_list(op)), ",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> Jason.encode!(value)
      end)

    assert build_conn()
           |> Plug.Conn.put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", "{\"operations\":[{" <> reordered <> "}]}")
           |> json_response(200) == %{"results" => [result]}

    for changed <- [
          Map.put(op, "rooms", Enum.reverse(op["rooms"])),
          Map.put(op, "extra", nil),
          put_in(op, ["metadata", "b"], [1.0, true, nil])
        ] do
      assert [%{"code" => "operation_id_conflict"}] = batch([changed])
    end

    [record] = Repo.all(Record)
    assert record.submission === op
    assert record.type == "open_group"
    assert record.result == result
  end

  test "concurrent retries execute once and durable commit order survives repo restart", %{
    options: options,
    repo: repo
  } do
    batch([opening()])

    pay =
      operation("pay", "record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(repo)
          Reservations.submit([pay])
        end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(Enum.uniq(results)) == 1
    assert [[%{"status" => "applied", "revision" => 2}]] = Enum.uniq(results)
    assert Repo.get!(Group, "group").deposit_paid_cents == 100
    records = Repo.all(from r in Record, order_by: r.id)
    assert Enum.map(records, & &1.operation_id) == ["open", "pay"]
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([pay]) == hd(results)
    assert Repo.all(from r in Record, order_by: r.id) == records
  end

  test "independent application processes share durable retry protection", %{options: options} do
    batch([opening()])
    pay = operation("external", "record_cash_payment", %{"amount_cents" => 100})
    directory = Path.dirname(options[:database])
    input = Path.join(directory, "submission.json")
    File.write!(input, Jason.encode!(pay))

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          output = Path.join(directory, "result-#{index}.json")

          arguments = [
            "run",
            "--no-compile",
            "--no-start",
            "test/support/operation_client.exs",
            options[:database],
            input,
            output
          ]

          {log, status} =
            System.cmd("mix", arguments, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

          assert status == 0, log
          output |> File.read!() |> Jason.decode!()
        end,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [first, second] = results
    assert first == second
    assert first == batch([pay])
    assert Repo.get!(Group, "group").revision == 2
    assert Repo.get!(Group, "group").deposit_paid_cents == 100
    assert Repo.aggregate(Record, :count) == 2
  end

  test "credit redemption and restoration retries do not change lots or allocations twice" do
    batch([
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100}),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("destination-open", "destination")
    ])

    redeem =
      operation("redeem", "apply_hotel_credit", %{
        "group_id" => "destination",
        "amount_cents" => 80
      })

    restore = operation("restore", "cancel_group", %{"group_id" => "destination"})
    [funded, retry] = batch([redeem, redeem])
    assert funded == retry
    assert funded["revision"] == 2
    assert Repo.aggregate(GroupStay.HotelCredit.Allocation, :count) == 1
    assert GroupStay.HotelCredit.balance("guest", ~D[2026-10-02]).available_cents == 30
    [cancelled, retry] = batch([restore, restore])
    assert cancelled == retry
    assert batch([redeem]) == [funded]
    assert Repo.aggregate(GroupStay.HotelCredit.Allocation, :count) == 0
    assert GroupStay.HotelCredit.balance("guest", ~D[2026-10-02]).available_cents == 110
    assert Reservations.ledger(~D[2026-10-02]).credit_liability_cents == 110
  end

  test "handled rejection rolls back domain writes while saving the audit result" do
    batch([opening()])
    op = operation("rejected", "record_cash_payment")

    result =
      Operations.execute(op, fn _ ->
        Repo.update_all(Group, set: [revision: 99])
        {:error, "invalid_amount"}
      end)

    assert Repo.get!(Group, "group").revision == 1
    assert Operations.get_result("rejected") == result
    assert Operations.execute(op, fn _ -> flunk("retry dispatched") end) == result
  end

  test "unexpected database faults abort HTTP processing, roll back all current writes and allow retries" do
    batch([opening()])

    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    first = operation("first", "record_cash_payment", %{"amount_cents" => 10})
    fault = operation("fault", "record_cash_payment", %{"amount_cents" => 20})
    later = operation("later", "record_cash_payment", %{"amount_cents" => 30})
    assert_error_sent 500, fn -> batch([first, fault, later]) end
    assert Repo.get!(Group, "group").deposit_paid_cents == 10
    assert Operations.get_result("first")["revision"] == 2
    assert Operations.get_result("fault") == nil
    assert Operations.get_result("later") == nil
    Repo.query!("DROP TRIGGER fail_audit")
    assert Enum.map(batch([first, fault, later]), & &1["revision"]) == [2, 3, 4]
    assert Repo.get!(Group, "group").deposit_paid_cents == 60
  end
end
