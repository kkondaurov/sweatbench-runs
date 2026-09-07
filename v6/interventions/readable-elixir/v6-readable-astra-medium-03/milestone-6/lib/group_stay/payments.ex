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
    {:ok, result} = Repo.transaction(fn -> read_statement(id) end)
    result
  end

  defp read_statement(id) do
    with {:ok, record} <- target(id, "payment_not_reconcilable") do
      amounts =
        Enum.reduce(allocations(id), Map.new(@fields, fn {_, field} -> {field, 0} end), fn slice,
                                                                                           amounts ->
          Map.update!(amounts, Map.fetch!(@fields, slice.disposition), &(&1 + slice.amount_cents))
        end)

      statement =
        Map.merge(amounts, %{
          payment_operation_id: id,
          original_group_id: record.result["group_id"],
          recorded_cents: record.result["amount_cents"]
        })

      statement =
        if Repo.exists?(from p in "transferred_payments", where: p.payment_operation_id == ^id),
          do: Map.put(statement, :held_by_group, held_by_group(id)),
          else: statement

      {:ok, statement}
    end
  end

  defp held_by_group(id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^id and a.disposition == "held",
        group_by: a.group_id,
        order_by: a.group_id,
        select: %{group_id: a.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp allocations(id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^id,
        order_by: [desc: a.allocation_order, desc: a.id]
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
        changes = correction_changes(group, removed, [], "reduced", amount)

        {:ok, changes,
         %{
           payment_operation_id: record.operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
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

      changes = correction_changes(group, removed, eligible, "charged_back", sum(eligible))

      {:ok, changes,
       %{
         payment_operation_id: record.operation_id,
         charged_back_cents: sum(eligible),
         outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
       }}
    end
  end

  def settle(slices, disposition, lot_id) do
    # Payments take their seniority from the allocations being settled here.
    # A transfer can reverse their original funding order. Keep a payment's
    # slices together so cumulative rounding assigns one entitlement per payment;
    # unattributed legacy cash remains the senior block.
    slices =
      slices
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {payment_id, allocations} ->
        {if(is_nil(payment_id), do: 0, else: 1),
         Enum.min_by(allocations, & &1.allocation_order).allocation_order}
      end)
      |> Enum.flat_map(fn {_payment_id, allocations} ->
        Enum.sort_by(allocations, & &1.allocation_order)
      end)

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
              disposition: disposition,
              allocation_order: slice.allocation_order
            })
        end

        removed =
          if used > 0 do
            Map.update(removed, slice.group_id, %{slice.room_id => used}, fn rooms ->
              Map.update(rooms, slice.room_id, used, &(&1 + used))
            end)
          else
            removed
          end

        {remaining - used, removed}
      end)

    removed
  end

  # Settlement counters belong to the group where cash settled. Corrections
  # advance every changed group once, plus the original addressed group even
  # when all of its payment's cash now lives elsewhere.
  defp correction_changes(original, removed, slices, disposition, amount) do
    settled = Enum.group_by(Enum.reject(slices, &(&1.disposition == "held")), & &1.group_id)
    ids = Enum.uniq([original.group_id | Map.keys(removed) ++ Map.keys(settled)])

    Enum.reduce(ids, nil, fn id, original_changes ->
      group = if id == original.group_id, do: original, else: Repo.get!(Group, id)

      changes =
        RoomAccounting.totals(RoomAccounting.remove_cash(group.rooms, Map.get(removed, id, %{})))

      history = Map.get(settled, id, [])

      changes =
        Map.merge(changes, %{
          refunded_cents: group.refunded_cents - disposition_total(history, "refunded"),
          retained_cents: group.retained_cents - disposition_total(history, "retained"),
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - disposition_total(history, "converted")
        })

      if id == original.group_id do
        field =
          if disposition == "reduced", do: :cash_reduced_cents, else: :cash_charged_back_cents

        Map.put(changes, field, Map.fetch!(group, field) + amount)
      else
        Repo.update!(
          Ecto.Changeset.change(group, Map.put(changes, :revision, group.revision + 1))
        )

        original_changes
      end
    end)
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp sum(slices), do: Enum.sum(Enum.map(slices, & &1.amount_cents))

  defp disposition_total(slices, disposition),
    do: slices |> Enum.filter(&(&1.disposition == disposition)) |> sum()
end
