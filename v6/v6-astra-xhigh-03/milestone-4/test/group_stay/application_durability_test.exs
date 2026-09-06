defmodule GroupStay.ApplicationDurabilityTest do
  use ExUnit.Case, async: false
  import GroupStay.OperationFixtures

  @moduletag :tmp_dir

  test "a fresh application process replays results and audit history from the same database", %{
    tmp_dir: directory
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 5000, "expected_revision" => 1}),
      operation("cancel_group", %{"expected_revision" => 1}),
      operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    input = write_input(directory, operations)
    first = run_process(directory, input, "first")
    second = run_process(directory, input, "second")

    assert first == second
    assert first["results"] == first["lookups"]

    assert Enum.map(first["results"], & &1["status"]) ==
             ~w(applied applied rejected applied applied)

    assert first["group"]["revision"] == 4
    assert first["ledger"]["cash_converted_to_credit_cents"] == 5000
    assert first["credit"]["available_cents"] == 5500
    assert Enum.map(first["audit"], & &1["payload"]) == operations
  end

  test "separate application processes coordinate concurrent retries through SQLite", %{
    tmp_dir: directory
  } do
    input = write_input(directory, [open_operation()])
    run_process(directory, input, "setup")
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    input = write_input(directory, List.duplicate(payment, 12))
    gate = Path.join(directory, "go")
    ready_paths = for index <- 1..2, do: Path.join(directory, "ready-#{index}")

    tasks =
      for {ready, index} <- Enum.with_index(ready_paths) do
        Task.async(fn -> run_process(directory, input, "writer-#{index}", [ready, gate]) end)
      end

    await_ready(ready_paths, System.monotonic_time(:millisecond) + 20_000)
    File.write!(gate, "go")
    outputs = Task.await_many(tasks, 30_000)

    assert [original] = outputs |> Enum.flat_map(& &1["results"]) |> Enum.uniq()
    assert original["status"] == "applied"
    assert original["revision"] == 2

    for output <- outputs do
      assert output["group"]["deposit_paid_cents"] == 100
      assert output["group"]["revision"] == 2
      assert output["ledger"]["cash_held_cents"] == 100
      assert length(output["audit"]) == 2
    end
  end

  test "room settlements, reductions, chargebacks and credit shortfalls survive application restarts",
       %{tmp_dir: directory} do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 15000}),
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      open_operation(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 5000}),
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 1000}),
      operation("charge_back_payment", %{"payment_operation_id" => "pay"})
    ]

    input = write_input(directory, operations)
    first = run_process(directory, input, "first")
    assert first == run_process(directory, input, "restart")
    assert Enum.all?(first["results"], &(&1["status"] == "applied"))
    assert first["ledger"]["cash_charged_back_cents"] == 14000
    assert first["ledger"]["cash_reduced_cents"] == 1000
    assert first["ledger"]["credit_shortfall_cents"] == 5000
    assert first["ledger"]["credit_liability_cents"] == 5000
    assert first["group"]["revision"] == 5

    assert first["payments"] == [
             %{
               "payment_operation_id" => "pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 15000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 14000
             }
           ]
  end

  defp write_input(directory, operations) do
    path = Path.join(directory, "input.json")
    File.write!(path, Jason.encode!(operations))
    path
  end

  defp run_process(directory, input, name, barrier_paths \\ []) do
    output = Path.join(directory, "#{name}.json")

    {log, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "test/support/durable_operations_process.exs",
          input,
          output
        ] ++ barrier_paths,
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", Path.join(directory, "application.db")},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    output |> File.read!() |> Jason.decode!()
  end

  defp await_ready(paths, deadline) do
    unless Enum.all?(paths, &File.exists?/1) do
      assert System.monotonic_time(:millisecond) < deadline, "application processes did not start"
      Process.sleep(20)
      await_ready(paths, deadline)
    end
  end
end
