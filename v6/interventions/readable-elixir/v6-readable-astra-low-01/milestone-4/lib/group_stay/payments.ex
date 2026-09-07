defmodule GroupStay.Payments do
  @moduledoc """
  Provider corrections and reconciliation of immutable recorded payments.
  Cash dispositions partition the original amount. Chargebacks reclassify settled
  history without replaying refunds and revoke only the associated credit entitlement.
  """
  import Ecto.Query
  alias GroupStay.{Repo, CashAllocation, RoomAccounting, Credits}
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.Group

  @dispositions ~w(held refunded retained converted_to_credit reduced charged_back)

  def target(id) do
    case Repo.get_by(Record, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, "payment_not_reconcilable"}
    end
  end

  def statement(id) do
    with {:ok, record} <- target(id) do
      amounts = totals(from a in CashAllocation, where: a.payment_operation_id == ^id)

      {:ok,
       Map.merge(amounts, %{
         payment_operation_id: id,
         original_group_id: record.result["group_id"],
         recorded_cents: record.result["amount_cents"]
       })}
    end
  end

  def ledger do
    CashAllocation
    |> totals()
    |> Map.new(fn {key, amount} ->
      {String.to_atom("cash_" <> Atom.to_string(key)), amount}
    end)
  end

  def reduce(group, op) do
    allocations = allocations(op["payment_operation_id"])
    held = Enum.filter(allocations, &(&1.disposition == "held"))
    available = Enum.sum(Enum.map(held, & &1.amount_cents))
    amount = op["amount_cents"]

    cond do
      available == 0 ->
        {:error, "payment_not_reducible"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > available ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        remove_held(held, amount, "reduced")
        finish(group, op, %{amount_cents: amount})
    end
  end

  def charge_back(group, op) do
    allocations = allocations(op["payment_operation_id"])

    amount =
      allocations
      |> Enum.reject(&(&1.disposition in ~w(reduced charged_back)))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    cond do
      amount == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")) ->
        {:error, "payment_not_chargeable"}

      true ->
        allocations
        |> Enum.filter(&(&1.disposition == "converted_to_credit"))
        |> Enum.group_by(& &1.lot_id)
        |> Enum.each(fn {lot_id, portions} ->
          Credits.claw_back(lot_id, Enum.sum(Enum.map(portions, & &1.entitlement_cents)))
        end)

        for allocation <- Enum.reverse(allocations), allocation.disposition != "reduced" do
          allocation |> Ecto.Changeset.change(disposition: "charged_back") |> Repo.update!()
        end

        finish(group, op, %{charged_back_cents: amount})
    end
  end

  defp finish(group, op, result) do
    group = RoomAccounting.refresh(group)
    group |> Ecto.Changeset.change(revision: group.revision + 1) |> Repo.update!()

    {:ok,
     Map.merge(result, %{
       payment_operation_id: op["payment_operation_id"],
       group_id: group.group_id,
       revision: group.revision + 1,
       outstanding_deposit_cents: Group.outstanding(group)
     })}
  end

  defp remove_held(allocations, amount, disposition) do
    Enum.reduce(Enum.reverse(allocations), amount, fn allocation, needed ->
      removed = min(needed, allocation.amount_cents)

      cond do
        removed == 0 ->
          :ok

        removed == allocation.amount_cents ->
          allocation |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()

        true ->
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed)
          |> Repo.update!()

          Repo.insert!(%CashAllocation{
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: removed,
            disposition: disposition
          })
      end

      needed - removed
    end)
  end

  defp allocations(id),
    do: Repo.all(from a in CashAllocation, where: a.payment_operation_id == ^id, order_by: a.id)

  defp totals(query) do
    amounts =
      Repo.all(
        from a in query,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(@dispositions, fn disposition ->
      {String.to_atom(disposition <> "_cents"), Map.get(amounts, disposition, 0)}
    end)
  end
end
