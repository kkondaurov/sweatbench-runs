defmodule GroupStay.Reservations.Payments do
  @moduledoc """
  Reconciles durable cash payments and records provider corrections.

  The audit result is immutable. Current cash dispositions live in room allocations,
  whose six categories partition the original recorded amount. Reductions touch held
  cash only; chargebacks reclassify every category except prior reductions.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

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
    with {:ok, record} <- find(operation_id, "payment_not_reconcilable") do
      totals = Map.new(@statement_fields, fn {_disposition, field} -> {field, 0} end)

      totals =
        Enum.reduce(allocations(record), totals, fn allocation, totals ->
          Map.update!(
            totals,
            Map.fetch!(@statement_fields, allocation.disposition),
            &(&1 + allocation.amount_cents)
          )
        end)

      {:ok,
       Map.merge(totals, %{
         payment_operation_id: operation_id,
         original_group_id: record.result["group_id"],
         recorded_cents: record.result["amount_cents"]
       })}
    end
  end

  def reduce(group, record, amount) do
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
        remove_held(held, amount, "reduced")

        changeset =
          group
          |> RoomAccounting.refresh()
          |> change(cash_reduced_cents: group.cash_reduced_cents + amount)

        {:ok, changeset,
         %{
           payment_operation_id: record.operation_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(group) + amount
         }}
    end
  end

  def charge_back(group, record) do
    allocations = allocations(record)
    remaining = Enum.reject(allocations, &(&1.disposition in ["reduced", "charged_back"]))
    amount = RoomAccounting.total(remaining)

    cond do
      amount == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")) ->
        {:error, "payment_not_chargeable"}

      true ->
        {held, settled} = Enum.split_with(remaining, &(&1.disposition == "held"))
        held_amount = RoomAccounting.total(held)
        remove_held(held, held_amount, "charged_back")
        Enum.each(settled, &RoomAccounting.move(&1, &1.amount_cents, "charged_back"))

        Repo.all(
          from entitlement in CreditEntitlement,
            where: entitlement.payment_operation_id == ^record.operation_id
        )
        |> Enum.each(&HotelCredit.revoke(&1.credit_lot_id, &1.amount_cents))

        changes =
          Enum.reduce(settled, %{}, fn allocation, changes ->
            field = Map.fetch!(@cash_fields, allocation.disposition)

            Map.update(
              changes,
              field,
              Map.fetch!(group, field) - allocation.amount_cents,
              &(&1 - allocation.amount_cents)
            )
          end)

        changes =
          Map.put(changes, :cash_charged_back_cents, group.cash_charged_back_cents + amount)

        {:ok, group |> RoomAccounting.refresh() |> change(changes),
         %{
           payment_operation_id: record.operation_id,
           charged_back_cents: amount,
           outstanding_deposit_cents: Group.outstanding_deposit(group) + held_amount
         }}
    end
  end

  defp allocations(record) do
    Repo.all(
      from allocation in RoomAllocation,
        where: allocation.payment_operation_id == ^record.operation_id,
        order_by: allocation.id
    )
  end

  defp remove_held(allocations, amount, disposition) do
    0 =
      allocations
      |> Enum.reverse()
      |> Enum.reduce(amount, fn allocation, needed ->
        used = min(needed, allocation.amount_cents)
        if used > 0, do: RoomAccounting.move(allocation, used, disposition)
        needed - used
      end)
  end
end
