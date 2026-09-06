defmodule GroupStay.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GroupStay.{Group, Repo, Reservations}

  test "competing conditional payments apply exactly once" do
    id = "concurrent-#{System.unique_integer([:positive])}"

    # These operations need independent, committed transactions, rather than the
    # shared rollback transaction used by ConnCase.
    Sandbox.unboxed_run(Repo, fn ->
      assert [%{status: "applied"}] =
               Reservations.batch([
                 %{
                   "operation_id" => "open",
                   "type" => "open_group",
                   "group_id" => id,
                   "guest_id" => "guest",
                   "property_id" => "hotel",
                   "occurred_on" => "2026-09-05",
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-13",
                   "rate_plan" => "flexible",
                   "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
                 }
               ])
    end)

    try do
      results =
        1..8
        |> Task.async_stream(
          fn index ->
            Sandbox.unboxed_run(Repo, fn ->
              [result] =
                Reservations.batch([
                  %{
                    "operation_id" => "payment-#{index}",
                    "type" => "record_cash_payment",
                    "group_id" => id,
                    "occurred_on" => "2026-09-05",
                    "amount_cents" => 100,
                    "expected_revision" => 1
                  }
                ])

              result
            end)
          end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1.status == "applied")) == 1
      stale = Enum.filter(results, &(&1.status == "rejected"))
      assert length(stale) == 7
      assert Enum.all?(stale, &(&1.code == "stale_revision" and &1.actual_revision == 2))

      Sandbox.unboxed_run(Repo, fn ->
        assert %{revision: 2, deposit_paid_cents: 100, outstanding_deposit_cents: 5900} =
                 Reservations.get_group(id)
      end)
    after
      Sandbox.unboxed_run(Repo, fn -> Repo.get!(Group, id) |> Repo.delete!() end)
    end
  end
end
