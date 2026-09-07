defmodule GroupStay.OperationsRestartTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  test "fresh application processes share durable outcomes, submissions, and accounting" do
    directory = Path.expand("tmp/restart-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    input = Path.join(directory, "operations.json")
    output = Path.join(directory, "result.json")
    database = Path.join(directory, "restart.db")

    operations = [
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "source-payment", "amount_cents" => 5}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 6}),
      operation("cancel_group", %{"group_id" => "next", "expected_revision" => 1}),
      operation("unknown", %{"metadata" => %{"values" => [true, nil, 1.5]}}),
      operation("record_cash_payment", %{
        "group_id" => "next",
        "operation_id" => "next-payment",
        "amount_cents" => 10_000
      }),
      operation("cancel_rooms", %{"group_id" => "next", "room_ids" => ["room-a"]}),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "next-payment",
        "amount_cents" => 500
      })
      |> Map.delete("group_id"),
      operation("charge_back_payment", %{"payment_operation_id" => "source-payment"})
      |> Map.delete("group_id"),
      open_group(%{"group_id" => "destination"}),
      transfer_deposit("next", "destination", 1000, %{
        "expected_revision" => 5,
        "destination_expected_revision" => 1
      })
    ]

    File.write!(input, Jason.encode!(operations))
    first = run_application(database, input, output)
    assert first["stored_before"] == List.duplicate(nil, length(operations))

    assert Enum.map(first["results"], & &1["status"]) ==
             [
               "applied",
               "applied",
               "applied",
               "applied",
               "applied",
               "rejected",
               "rejected",
               "applied",
               "applied",
               "applied",
               "applied",
               "applied",
               "applied"
             ]

    assert Enum.at(first["results"], 5)["actual_revision"] == 2
    assert first["ledger"]["cash_converted_to_credit_cents"] == 0
    assert first["ledger"]["credit_liability_cents"] == 6
    assert first["ledger"]["credit_shortfall_cents"] == 6
    assert first["ledger"]["cash_charged_back_cents"] == 5
    assert first["ledger"]["cash_reduced_cents"] == 500
    assert first["ledger"]["cash_refunded_cents"] == 1006
    assert first["ledger"]["cash_held_cents"] == 8494
    statement = Enum.find(first["statements"], &(&1["payment_operation_id"] == "next-payment"))

    assert statement["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 1000},
             %{"group_id" => "next", "amount_cents" => 7494}
           ]

    restarted = run_application(database, input, output)
    assert restarted["stored_before"] == first["results"]
    assert Map.delete(restarted, "stored_before") == Map.delete(first, "stored_before")
  end

  test "finance inception, movements, and automatic expiry survive a fresh application process" do
    directory =
      Path.expand("tmp/reporting-restart-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    input = Path.join(directory, "operations.json")
    output = Path.join(directory, "result.json")
    database = Path.join(directory, "restart.db")

    operations = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-03"})
      |> Map.delete("group_id"),
      operation("record_cash_payment", %{"amount_cents" => 50, "occurred_on" => "2026-10-04"}),
      operation("cancel_group", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-10-04"
      }),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{
        "group_id" => "next",
        "amount_cents" => 100,
        "occurred_on" => "2026-10-04"
      })
    ]

    File.write!(input, Jason.encode!(operations))
    first = run_application(database, input, output)
    assert Enum.all?(first["results"], &(&1["status"] == "applied"))

    assert [%{"opening_held_cents" => 100, "closing_held_cents" => 100}] =
             first["reports"]["2026-10-03"]["cash"]

    assert first["reports"]["2026-10-04"]["credit"]["movements"]["issued_cents"] == 165
    assert first["reports"]["2027-10-05"]["credit"]["movements"]["expired_cents"] == 65
    assert first["reports"]["2027-10-05"]["credit"]["closing_liability_cents"] == 100

    restarted = run_application(database, input, output)
    assert restarted["stored_before"] == first["results"]
    assert Map.delete(restarted, "stored_before") == Map.delete(first, "stored_before")
  end

  defp run_application(database, input, output) do
    {logs, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-S",
          "mix",
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "test/support/operations_restart_probe.exs",
          input,
          output
        ],
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", database},
          {"PHX_SERVER", nil},
          {"RELEASE_NAME", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, logs
    output |> File.read!() |> Jason.decode!()
  end
end
