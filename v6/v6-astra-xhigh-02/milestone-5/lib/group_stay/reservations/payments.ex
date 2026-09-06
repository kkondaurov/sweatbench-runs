defmodule GroupStay.Reservations.Payments do
  @moduledoc false
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Reservations.{HotelCredit, RoomAccounting, RoomAllocation}

  @dispositions [
    held_cents: "held",
    refunded_cents: "refunded",
    retained_cents: "retained",
    converted_to_credit_cents: "converted_to_credit",
    reduced_cents: "reduced",
    charged_back_cents: "charged_back"
  ]

  def find(operation_id, invalid_code) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, %{code: "operation_not_found"}}

      %Operation{type: "record_cash_payment", result: %{"status" => "applied"}} = payment ->
        {:ok, payment}

      _ ->
        {:error, %{code: invalid_code}}
    end
  end

  def allocations(payment) do
    Repo.all(from a in RoomAllocation, where: a.payment_operation_id == ^payment.operation_id)
  end

  def statement(operation_id) do
    # The audit record and all current dispositions share one read snapshot.
    {:ok, result} =
      Repo.transact(fn ->
        result =
          with {:ok, payment} <- find(operation_id, "payment_not_reconcilable") do
            allocations = allocations(payment)
            balances = Enum.group_by(allocations, & &1.disposition)

            amounts =
              Map.new(@dispositions, fn {field, disposition} ->
                {field, RoomAccounting.total(Map.get(balances, disposition, []))}
              end)

            amounts =
              if Enum.any?(allocations, & &1.transferred) do
                held_by_group =
                  balances
                  |> Map.get("held", [])
                  |> Enum.group_by(& &1.group_id)
                  |> Enum.sort_by(fn {group_id, _} -> group_id end)
                  |> Enum.map(fn {group_id, held} ->
                    %{group_id: group_id, amount_cents: RoomAccounting.total(held)}
                  end)

                Map.put(amounts, :held_by_group, held_by_group)
              else
                amounts
              end

            {:ok,
             Map.merge(amounts, %{
               payment_operation_id: payment.operation_id,
               original_group_id: payment.result["group_id"],
               recorded_cents: payment.result["amount_cents"]
             })}
          end

        {:ok, result}
      end)

    result
  end

  # Repeated corrections and replacement payments can exceed SQLite's integer
  # range in one group. Each allocation fits; sum the cumulative totals in Elixir.
  def reversal_totals do
    Repo.all(
      from a in RoomAllocation,
        where: a.disposition in ["reduced", "charged_back"],
        select: {a.disposition, a.amount_cents}
    )
    |> Enum.reduce(%{cash_reduced_cents: 0, cash_charged_back_cents: 0}, fn {disposition, amount},
                                                                            totals ->
      field = if disposition == "reduced", do: :cash_reduced_cents, else: :cash_charged_back_cents
      Map.update!(totals, field, &(&1 + amount))
    end)
  end

  def reduce(allocations, amount) do
    allocations
    |> RoomAccounting.remove_held(amount, "reduced")
    |> Map.new(&{&1.group_id, []})
  end

  def charge_back(payment, allocations) do
    remaining = Enum.filter(allocations, &(&1.disposition not in ["reduced", "charged_back"]))
    balances = Enum.group_by(remaining, & &1.disposition)
    amount = RoomAccounting.total(remaining)
    held = RoomAccounting.total(Map.get(balances, "held", []))
    RoomAccounting.remove_held(remaining, held, "charged_back")

    for allocation <- remaining, allocation.disposition != "held", allocation.amount_cents > 0 do
      RoomAccounting.move(allocation, allocation.amount_cents, "charged_back")
    end

    HotelCredit.revoke(payment.operation_id)

    # Settlements belong to the group that held the cash at cancellation, which
    # can differ from the original payment group. Return deltas for each owner.
    changes =
      remaining
      |> Enum.group_by(& &1.group_id)
      |> Map.new(fn {group_id, allocations} ->
        balances = Enum.group_by(allocations, & &1.disposition)

        {group_id,
         Enum.map(
           [
             cash_refunded_cents: "refunded",
             cash_retained_cents: "retained",
             cash_converted_to_credit_cents: "converted_to_credit"
           ],
           fn {field, disposition} ->
             {field, -RoomAccounting.total(Map.get(balances, disposition, []))}
           end
         )}
      end)

    {changes, amount}
  end
end
