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
      operation("record_cash_payment", %{"amount_cents" => 5}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 6}),
      operation("cancel_group", %{"group_id" => "next", "expected_revision" => 1}),
      operation("unknown", %{"metadata" => %{"values" => [true, nil, 1.5]}})
    ]

    File.write!(input, Jason.encode!(operations))
    first = run_application(database, input, output)
    assert first["stored_before"] == List.duplicate(nil, length(operations))

    assert Enum.map(first["results"], & &1["status"]) ==
             ["applied", "applied", "applied", "applied", "applied", "rejected", "rejected"]

    assert Enum.at(first["results"], 5)["actual_revision"] == 2
    assert first["ledger"]["cash_converted_to_credit_cents"] == 5
    assert first["ledger"]["credit_liability_cents"] == 6

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
