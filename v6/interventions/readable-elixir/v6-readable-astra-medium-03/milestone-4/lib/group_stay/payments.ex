defmodule GroupStay.Payments do
  @moduledoc """
  Reconciles durable cash payments across their current dispositions. Original
  operation results are immutable; corrections move accounting slices instead.
  Entitlements use cumulative rounding in funding order, independently per lot.
  """
  import Ecto.Query
  alias GroupStay.{Repo, HotelCredit}
  alias GroupStay.Operations.Record
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Reservations.{Group, RoomAccounting}

  @fields %{
    "held" => :held_cents,
    "refunded" => :refunded_cents,
    "retained" => :retained_cents,
    "converted" => :converted_to_credit_cents,
    "reduced" => :reduced_cents,
    "charged_back" => :charged_back_cents
  }

  def target(id, error) do
    case Repo.get_by(Record, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, error}
    end
  end

  def statement(id) do
    with {:ok, record} <- target(id, "payment_not_reconcilable") do
      amounts =
        Enum.reduce(allocations(id), Map.new(@fields, fn {_, field} -> {field, 0} end), fn slice,
                                                                                           amounts ->
          Map.update!(amounts, Map.fetch!(@fields, slice.disposition), &(&1 + slice.amount_cents))
        end)

      {:ok,
       Map.merge(amounts, %{
         payment_operation_id: id,
         original_group_id: record.result["group_id"],
         recorded_cents: record.result["amount_cents"]
       })}
    end
  end

  defp allocations(id) do
    Repo.all(
      from a in CashAllocation, where: a.payment_operation_id == ^id, order_by: [desc: a.id]
    )
  end

  def reduce(group, record, op) do
    held = Enum.filter(allocations(record.operation_id), &(&1.disposition == "held"))
    total = Enum.sum(Enum.map(held, & &1.amount_cents))
    amount = op["amount_cents"]

    cond do
      total == 0 ->
        {:error, "payment_not_reducible"}

      not Map.has_key?(op, "amount_cents") ->
        {:error, "invalid_operation"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > total ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        removed = move_held(held, amount, "reduced")
        changes = RoomAccounting.totals(RoomAccounting.remove_cash(group.rooms, removed))

        {:ok, Map.put(changes, :cash_reduced_cents, group.cash_reduced_cents + amount),
         %{
           payment_operation_id: record.operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding(group) + amount
         }}
    end
  end

  def charge_back(group, record) do
    slices = allocations(record.operation_id)
    eligible = Enum.reject(slices, &(&1.disposition == "reduced"))

    if eligible == [] or Enum.any?(eligible, &(&1.disposition == "charged_back")) do
      {:error, "payment_not_chargeable"}
    else
      held = Enum.filter(eligible, &(&1.disposition == "held"))
      held_total = sum(held)
      removed = move_held(held, held_total, "charged_back")

      for slice <- eligible, slice.disposition != "held" do
        if slice.disposition == "converted",
          do: HotelCredit.revoke(slice.credit_lot_id, slice.entitlement_cents)

        Repo.update!(Ecto.Changeset.change(slice, disposition: "charged_back"))
      end

      changes = RoomAccounting.totals(RoomAccounting.remove_cash(group.rooms, removed))

      changes =
        Map.merge(changes, %{
          refunded_cents: group.refunded_cents - disposition_total(eligible, "refunded"),
          retained_cents: group.retained_cents - disposition_total(eligible, "retained"),
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - disposition_total(eligible, "converted"),
          cash_charged_back_cents: group.cash_charged_back_cents + sum(eligible)
        })

      {:ok, changes,
       %{
         payment_operation_id: record.operation_id,
         charged_back_cents: sum(eligible),
         outstanding_deposit_cents: Group.outstanding(group) + held_total
       }}
    end
  end

  def settle(slices, disposition, lot_id) do
    # Durable sequence, rather than the provider's business date, determines seniority.
    payment_ids =
      slices |> Enum.map(& &1.payment_operation_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    order =
      Repo.all(
        from r in Record,
          where: r.operation_id in ^payment_ids,
          select: {r.operation_id, r.id}
      )
      |> Map.new()

    slices = Enum.sort_by(slices, &{Map.get(order, &1.payment_operation_id, 0), &1.id})

    Enum.reduce(slices, 0, fn slice, principal ->
      entitlement =
        if lot_id,
          do: bonus_value(principal + slice.amount_cents) - bonus_value(principal),
          else: 0

      Repo.update!(
        Ecto.Changeset.change(slice,
          disposition: disposition,
          credit_lot_id: lot_id,
          entitlement_cents: entitlement
        )
      )

      principal + slice.amount_cents
    end)
  end

  defp move_held(slices, amount, disposition) do
    {0, removed} =
      Enum.reduce(slices, {amount, %{}}, fn slice, {remaining, removed} ->
        used = min(remaining, slice.amount_cents)

        cond do
          used == 0 ->
            :ok

          used == slice.amount_cents ->
            Repo.update!(Ecto.Changeset.change(slice, disposition: disposition))

          true ->
            Repo.update!(Ecto.Changeset.change(slice, amount_cents: slice.amount_cents - used))

            Repo.insert!(%CashAllocation{
              group_id: slice.group_id,
              room_id: slice.room_id,
              payment_operation_id: slice.payment_operation_id,
              amount_cents: used,
              disposition: disposition
            })
        end

        {remaining - used, Map.update(removed, slice.room_id, used, &(&1 + used))}
      end)

    removed
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp sum(slices), do: Enum.sum(Enum.map(slices, & &1.amount_cents))

  defp disposition_total(slices, disposition),
    do: slices |> Enum.filter(&(&1.disposition == disposition)) |> sum()
end
