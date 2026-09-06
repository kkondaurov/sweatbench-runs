defmodule GroupStay.Payments do
  @moduledoc "Current dispositions of durably recorded cash payments."
  import Ecto.Query
  alias GroupStay.{FundingAllocation, HotelCredit, Operation, Repo, RoomAccounting}

  def target(id), do: Repo.get_by(Operation, operation_id: id)

  def cash_payment?(record),
    do: record.type == "record_cash_payment" and record.result["status"] == "applied"

  def allocations(id) do
    Repo.all(
      from a in FundingAllocation,
        where: a.payment_operation_id == ^id,
        order_by: [desc: a.id]
    )
  end

  def statement(id) do
    # The target and all dispositions are read from the same snapshot.
    {:ok, result} =
      Repo.transaction(fn ->
        case target(id) do
          nil ->
            {:error, :not_found, "operation_not_found"}

          record ->
            if cash_payment?(record) do
              initial = %{
                payment_operation_id: id,
                original_group_id: record.result["group_id"],
                recorded_cents: record.result["amount_cents"],
                held_cents: 0,
                refunded_cents: 0,
                retained_cents: 0,
                converted_to_credit_cents: 0,
                reduced_cents: 0,
                charged_back_cents: 0
              }

              allocations = allocations(id)

              statement =
                Enum.reduce(allocations, initial, fn a, totals ->
                  key = disposition_key(a.disposition)
                  Map.update!(totals, key, &(&1 + a.amount_cents))
                end)

              statement =
                if Enum.any?(allocations, & &1.transferred) do
                  held_by_group =
                    allocations
                    |> Enum.filter(&(&1.disposition == "held"))
                    |> Enum.group_by(& &1.group_id)
                    |> Enum.sort_by(&elem(&1, 0))
                    |> Enum.map(fn {group_id, held} ->
                      %{group_id: group_id, amount_cents: RoomAccounting.sum(held)}
                    end)

                  Map.put(statement, :held_by_group, held_by_group)
                else
                  statement
                end

              {:ok, statement}
            else
              {:error, :unprocessable_entity, "payment_not_reconcilable"}
            end
        end
      end)

    result
  end

  def reduce(allocations, amount) do
    {_, removed} =
      Enum.reduce(allocations, {amount, []}, fn a, {left, removed_allocations} ->
        removed = min(left, a.amount_cents)

        if removed > 0 do
          RoomAccounting.move(a, removed, "reduced")
          {left - removed, [%{a | amount_cents: removed} | removed_allocations]}
        else
          {left, removed_allocations}
        end
      end)

    removed
  end

  def charge_back(payment_id, allocations) do
    for a <- allocations,
        a.disposition != "reduced",
        do: RoomAccounting.move(a, a.amount_cents, "charged_back")

    HotelCredit.revoke(payment_id)
  end

  defp disposition_key("held"), do: :held_cents
  defp disposition_key("refunded"), do: :refunded_cents
  defp disposition_key("retained"), do: :retained_cents
  defp disposition_key("converted_to_credit"), do: :converted_to_credit_cents
  defp disposition_key("reduced"), do: :reduced_cents
  defp disposition_key("charged_back"), do: :charged_back_cents
end
