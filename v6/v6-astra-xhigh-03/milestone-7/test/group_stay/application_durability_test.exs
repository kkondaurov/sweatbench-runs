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

  test "transferred provenance, corrections, revisions and exact results survive application restarts",
       %{tmp_dir: directory} do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 15000}),
      open_operation(%{"group_id" => "destination"}),
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "destination",
        "amount_cents" => 8000
      }),
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 1000}),
      operation("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["room-b"],
        "refund_method" => "hotel_credit"
      }),
      operation("apply_hotel_credit", %{"amount_cents" => 4000}),
      open_operation(%{"group_id" => "credit-target"}),
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "credit-target",
        "amount_cents" => 3000
      }),
      operation("charge_back_payment", %{"payment_operation_id" => "pay"})
    ]

    input = write_input(directory, operations)
    first = run_process(directory, input, "first")
    assert first == run_process(directory, input, "restart")
    assert first["results"] == first["lookups"]
    assert Enum.all?(first["results"], &(&1["status"] == "applied"))
    assert first["group"]["revision"] == 7

    assert Enum.map(first["groups"], &{&1["group_id"], &1["revision"]}) ==
             [{"credit-target", 2}, {"destination", 5}, {"group-81", 7}]

    assert first["ledger"]["cash_charged_back_cents"] == 14000
    assert first["ledger"]["cash_reduced_cents"] == 1000
    assert first["ledger"]["credit_shortfall_cents"] == 4000
    assert first["ledger"]["credit_liability_cents"] == 4000
    assert [statement] = first["payments"]
    assert statement["held_by_group"] == []
    assert statement["charged_back_cents"] == 14000
    assert Enum.map(first["audit"], & &1["payload"]) == operations
  end

  test "separate processes apply concurrent transfer retries only once", %{tmp_dir: directory} do
    input =
      write_input(directory, [
        open_operation(),
        open_operation(%{"group_id" => "destination"}),
        operation("record_cash_payment", %{"amount_cents" => 100})
      ])

    run_process(directory, input, "setup")

    transfer =
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "destination",
        "amount_cents" => 60,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    input = write_input(directory, List.duplicate(transfer, 12))
    gate = Path.join(directory, "go")
    ready_paths = for index <- 1..2, do: Path.join(directory, "ready-#{index}")

    tasks =
      for {ready, index} <- Enum.with_index(ready_paths) do
        Task.async(fn -> run_process(directory, input, "writer-#{index}", [ready, gate]) end)
      end

    await_ready(ready_paths, System.monotonic_time(:millisecond) + 20_000)
    File.write!(gate, "go")
    outputs = Task.await_many(tasks, 30_000)
    assert [result] = outputs |> Enum.flat_map(& &1["results"]) |> Enum.uniq()
    assert result["status"] == "applied"
    assert result["source_revision"] == 3
    assert result["destination_revision"] == 2

    for output <- outputs do
      assert Enum.map(output["groups"], &{&1["deposit_paid_cents"], &1["revision"]}) == [
               {60, 2},
               {40, 3}
             ]

      assert output["ledger"]["cash_held_cents"] == 100
      assert length(output["audit"]) == 4
    end
  end

  test "finance inception, movements and scheduled expiry survive full application restarts", %{
    tmp_dir: directory
  } do
    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-11-26"
    }

    operations = [
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100}),
      start,
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      operation("charge_back_payment", %{
        "payment_operation_id" => "pay",
        "occurred_on" => "2027-11-28"
      })
    ]

    input = write_input(directory, operations)
    first = run_process(directory, input, "first")
    assert first == run_process(directory, input, "restart")
    assert first["results"] == first["lookups"]
    assert Enum.all?(first["results"], &(&1["status"] == "applied"))
    reports = first["finance_reports"]
    assert [cash] = reports["2026-11-26"]["cash"]
    assert cash["opening_held_cents"] == 100
    assert cash["movements"]["converted_to_credit_cents"] == 100
    assert cash["closing_held_cents"] == 0
    assert reports["2026-11-26"]["credit"]["movements"]["issued_cents"] == 110
    assert reports["2027-11-27"]["credit"]["movements"]["expired_cents"] == 110
    assert reports["2027-11-27"]["credit"]["closing_liability_cents"] == 0
  end

  test "separate processes serialize start and payment retries without duplicate finance postings",
       %{
         tmp_dir: directory
       } do
    input = write_input(directory, [open_operation()])
    run_process(directory, input, "setup")

    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-11-26"
    }

    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    input = write_input(directory, List.duplicate(start, 6) ++ List.duplicate(payment, 6))
    gate = Path.join(directory, "go")
    ready_paths = for index <- 1..2, do: Path.join(directory, "ready-#{index}")

    tasks =
      for {ready, index} <- Enum.with_index(ready_paths) do
        Task.async(fn -> run_process(directory, input, "writer-#{index}", [ready, gate]) end)
      end

    await_ready(ready_paths, System.monotonic_time(:millisecond) + 20_000)
    File.write!(gate, "go")
    outputs = Task.await_many(tasks, 30_000)

    for output <- outputs do
      assert Enum.all?(output["results"], &(&1["status"] == "applied"))
      assert length(output["audit"]) == 3
      assert [cash] = output["finance_reports"]["2026-11-26"]["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["movements"]["received_cents"] == 100
      assert cash["closing_held_cents"] == 100
    end
  end

  test "published report bytes and fixed late posting dates survive restarts and subsequent closes",
       %{tmp_dir: directory} do
    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-11-26"
    }

    operations = [
      open_operation(),
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-11-26"
      },
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100}),
      close
    ]

    input = write_input(directory, operations)
    first = run_process(directory, input, "first")
    assert first == run_process(directory, input, "restart")
    published = first["finance_report_bodies"]["2026-11-26"]

    operations =
      operations ++
        [
          operation("cancel_group", %{"refund_method" => "hotel_credit"}),
          Map.merge(close, %{"operation_id" => "close-expiry", "period_end_on" => "2027-11-27"})
        ]

    input = write_input(directory, operations)
    second = run_process(directory, input, "second")
    assert second == run_process(directory, input, "second-restart")
    assert second["finance_report_bodies"]["2026-11-26"] == published

    assert second["finance_reports"]["2026-11-27"]["late_adjustments"]["credit"]["issued_cents"] ==
             110

    input =
      write_input(
        directory,
        operations ++ [operation("charge_back_payment", %{"payment_operation_id" => "pay"})]
      )

    third = run_process(directory, input, "third")
    assert third == run_process(directory, input, "third-restart")

    for date <- ~w(2026-11-26 2026-11-27 2026-11-28 2027-11-27) do
      assert third["finance_report_bodies"][date] == second["finance_report_bodies"][date]
    end

    assert third["finance_reports"]["2027-11-28"]["late_adjustments"]["credit"]["revoked_cents"] ==
             110

    assert third["results"] == third["lookups"]
  end

  test "separate processes serialize close and correction retries without duplicate late movements",
       %{tmp_dir: directory} do
    input =
      write_input(directory, [
        open_operation(),
        %{
          "operation_id" => "start",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-11-26"
        },
        operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100})
      ])

    run_process(directory, input, "setup")

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-11-26"
    }

    correction =
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 25})

    input = write_input(directory, List.duplicate(close, 6) ++ List.duplicate(correction, 6))
    gate = Path.join(directory, "go")
    ready_paths = for index <- 1..2, do: Path.join(directory, "ready-#{index}")

    tasks =
      for {ready, index} <- Enum.with_index(ready_paths) do
        Task.async(fn -> run_process(directory, input, "writer-#{index}", [ready, gate]) end)
      end

    await_ready(ready_paths, System.monotonic_time(:millisecond) + 20_000)
    File.write!(gate, "go")

    for output <- Task.await_many(tasks, 30_000) do
      assert Enum.all?(output["results"], &(&1["status"] == "applied"))
      assert length(output["audit"]) == 5
      assert output["group"]["revision"] == 3
      assert [cash] = output["finance_reports"]["2026-11-26"]["cash"]
      assert cash["closing_held_cents"] == 100
      assert [cash] = output["finance_reports"]["2026-11-27"]["cash"]
      assert cash["closing_held_cents"] == 75
      assert cash["movements"]["reduced_cents"] == 0
      assert [late] = output["finance_reports"]["2026-11-27"]["late_adjustments"]["cash"]
      assert late["movements"]["reduced_cents"] == 25
    end
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
