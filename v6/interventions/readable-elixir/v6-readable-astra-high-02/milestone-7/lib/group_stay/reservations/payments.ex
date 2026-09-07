defmodule GroupStay.Reservations.Payments do
  @moduledoc """
  Reconciles durable cash payments and records provider corrections.

  The audit result is immutable. Current cash dispositions live in room allocations,
  whose six categories partition the original recorded amount. Reductions touch held
  cash only; chargebacks reclassify every category except prior reductions. Both
  follow allocations across transfers, advancing each changed group's revision
  while leaving the original payment result untouched.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [apply_changes: 1, change: 2]

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditEntitlement,
    Group,
    HotelCredit,
    OperationRecord,
    RoomAccounting,
    RoomAllocation
  }

  @statement_fields %{
    "held" => :held_cents,
    "refunded" => :refunded_cents,
    "retained" => :retained_cents,
    "converted_to_credit" => :converted_to_credit_cents,
    "reduced" => :reduced_cents,
    "charged_back" => :charged_back_cents
  }

  @cash_fields %{
    "refunded" => :cash_refunded_cents,
    "retained" => :cash_retained_cents,
    "converted_to_credit" => :cash_converted_to_credit_cents
  }

  def find(operation_id, error) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, "operation_not_found"}
      %{type: "record_cash_payment", result: %{"status" => "applied"}} = record -> {:ok, record}
      _ -> {:error, error}
    end
  end

  def statement(operation_id) do
    {:ok, result} = Repo.transaction(fn -> build_statement(operation_id) end)
    result
  end

  defp build_statement(operation_id) do
    with {:ok, record} <- find(operation_id, "payment_not_reconcilable") do
      allocations = allocations(record)
      totals = Map.new(@statement_fields, fn {_disposition, field} -> {field, 0} end)

      totals =
        Enum.reduce(allocations, totals, fn allocation, totals ->
          Map.update!(
            totals,
            Map.fetch!(@statement_fields, allocation.disposition),
            &(&1 + allocation.amount_cents)
          )
        end)

      {:ok,
       totals
       |> maybe_include_groups(allocations)
       |> Map.merge(%{
         payment_operation_id: operation_id,
         original_group_id: record.result["group_id"],
         recorded_cents: record.result["amount_cents"]
       })}
    end
  end

  def reduce(group, record, amount, reporting) do
    held = record |> allocations() |> Enum.filter(&(&1.disposition == "held"))
    available = RoomAccounting.total(held)

    cond do
      available == 0 ->
        {:error, "payment_not_reducible"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > available ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        removed = remove_held(held, amount, "reduced", reporting)
        changeset = refresh_corrected_groups(group, removed, :cash_reduced_cents)

        {:ok, changeset,
         %{
           payment_operation_id: record.operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(apply_changes(changeset))
         }}
    end
  end

  def charge_back(group, record, reporting) do
    allocations = allocations(record)
    remaining = Enum.reject(allocations, &(&1.disposition in ["reduced", "charged_back"]))
    amount = RoomAccounting.total(remaining)

    cond do
      amount == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")) ->
        {:error, "payment_not_chargeable"}

      true ->
        {held, settled} = Enum.split_with(remaining, &(&1.disposition == "held"))
        held_amount = RoomAccounting.total(held)
        remove_held(held, held_amount, "charged_back", reporting)
        Enum.each(settled, &RoomAccounting.move(&1, &1.amount_cents, "charged_back", reporting))

        Repo.all(
          from entitlement in CreditEntitlement,
            where: entitlement.payment_operation_id == ^record.operation_id
        )
        |> Enum.each(&HotelCredit.revoke(&1.credit_lot_id, &1.amount_cents, reporting))

        changeset = refresh_corrected_groups(group, remaining, :cash_charged_back_cents)

        {:ok, changeset,
         %{
           payment_operation_id: record.operation_id,
           charged_back_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(apply_changes(changeset))
         }}
    end
  end

  defp allocations(record) do
    Repo.all(
      from allocation in RoomAllocation,
        where: allocation.payment_operation_id == ^record.operation_id,
        order_by: allocation.id,
        preload: [:room]
    )
  end

  defp remove_held(allocations, amount, disposition, reporting) do
    {0, removed} =
      allocations
      |> Enum.reverse()
      |> Enum.reduce({amount, []}, fn allocation, {needed, removed} ->
        used = min(needed, allocation.amount_cents)

        if used > 0 do
          RoomAccounting.move(allocation, used, disposition, reporting)
          {needed - used, [%{allocation | amount_cents: used} | removed]}
        else
          {needed, removed}
        end
      end)

    removed
  end

  # Cash settlement counters belong to the group where that cash was disposed of.
  # Refresh each affected group once, even when several rooms or dispositions changed.
  # The caller persists the addressed group's changeset and advances its revision;
  # it must advance even when all corrected cash is now held or settled elsewhere.
  defp refresh_corrected_groups(original, allocations, counter) do
    {original_slices, other_groups} =
      allocations
      |> Enum.group_by(& &1.room.group_id)
      |> Map.pop(original.group_id, [])

    Enum.each(other_groups, fn {group_id, slices} ->
      group = Repo.get!(Group, group_id)

      group
      |> correction_changeset(slices, counter)
      |> change(revision: group.revision + 1)
      |> Repo.update!()
    end)

    correction_changeset(original, original_slices, counter)
  end

  defp correction_changeset(group, allocations, counter) do
    changes =
      Enum.reduce(allocations, %{}, fn allocation, changes ->
        case Map.fetch(@cash_fields, allocation.disposition) do
          {:ok, field} ->
            Map.update(
              changes,
              field,
              Map.fetch!(group, field) - allocation.amount_cents,
              &(&1 - allocation.amount_cents)
            )

          :error ->
            changes
        end
      end)
      |> Map.put(counter, Map.fetch!(group, counter) + RoomAccounting.total(allocations))

    group |> RoomAccounting.refresh() |> change(changes)
  end

  defp maybe_include_groups(statement, allocations) do
    if Enum.any?(allocations, & &1.transferred) do
      held_by_group =
        allocations
        |> Enum.filter(&(&1.disposition == "held"))
        |> Enum.group_by(& &1.room.group_id)
        |> Enum.sort_by(fn {group_id, _} -> group_id end)
        |> Enum.map(fn {group_id, slices} ->
          %{group_id: group_id, amount_cents: RoomAccounting.total(slices)}
        end)

      Map.put(statement, :held_by_group, held_by_group)
    else
      statement
    end
  end
end
