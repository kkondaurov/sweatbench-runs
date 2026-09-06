defmodule GroupStay.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GroupStay.{Group, Repo, Reservations, Operation}
  import Ecto.Query

  test "competing conditional payments apply exactly once" do
    id = "concurrent-#{System.unique_integer([:positive])}"

    # These operations need independent, committed transactions, rather than the
    # shared rollback transaction used by ConnCase.
    Sandbox.unboxed_run(Repo, fn ->
      assert [%{status: "applied"}] =
               Reservations.batch([
                 %{
                   "operation_id" => "#{id}-open",
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
                    "operation_id" => "#{id}-payment-#{index}",
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
      Sandbox.unboxed_run(Repo, fn ->
        Repo.get!(Group, id) |> Repo.delete!()
        operation_ids = ["#{id}-open" | Enum.map(1..8, &"#{id}-payment-#{&1}")]
        Repo.delete_all(from o in Operation, where: o.operation_id in ^operation_ids)
      end)
    end
  end

  test "competing groups cannot spend the same guest credit twice" do
    guest = "credit-race-#{System.unique_integer([:positive])}"
    ids = Enum.map(1..2, &"#{guest}-#{&1}")

    lot =
      Sandbox.unboxed_run(Repo, fn ->
        for id <- ids do
          Repo.insert!(%Group{
            group_id: id,
            guest_id: guest,
            property_id: "hotel",
            booked_on: ~D[2027-01-01],
            arrival_on: ~D[2027-06-01],
            departure_on: ~D[2027-06-02],
            rate_plan: "flexible",
            policy_version: "flex-30",
            rooms: [],
            lodging_total_cents: 1000,
            deposit_due_cents: 200
          })
        end

        Repo.insert!(%GroupStay.CreditLot{
          guest_id: guest,
          source_operation_id: guest,
          remaining_cents: 110,
          expires_on: ~D[2028-01-01]
        })
      end)

    try do
      results =
        ids
        |> Task.async_stream(fn id ->
          Sandbox.unboxed_run(Repo, fn ->
            [result] =
              Reservations.batch([
                %{
                  "type" => "apply_hotel_credit",
                  "group_id" => id,
                  "operation_id" => id,
                  "occurred_on" => "2027-01-01",
                  "amount_cents" => 110,
                  "expected_revision" => 1
                }
              ])

            result
          end)
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1.status == "applied")) == 1
      assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 1

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.get!(GroupStay.CreditLot, lot.id).remaining_cents == 0
        assert Enum.sum(Enum.map(ids, &Repo.get!(Group, &1).credit_paid_cents)) == 110
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        import Ecto.Query
        Repo.delete_all(from a in GroupStay.CreditAllocation, where: a.group_id in ^ids)
        Repo.delete_all(from g in Group, where: g.group_id in ^ids)
        Repo.delete!(lot)
        Repo.delete_all(from o in Operation, where: o.operation_id in ^ids)
      end)
    end
  end
end
