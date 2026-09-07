defmodule GroupStay.Reservations.CashPayments do
  @moduledoc """
  Tracks payment provenance from room funding through every cash disposition.

  The immutable operation journal identifies valid payments. Allocation balances
  describe their current disposition without rewriting the original result.
  All mutations are called under the reservations transaction's write lock.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.{Finance, Repo}

  alias GroupStay.Reservations.{
    AllocationOrder,
    CashAllocation,
    CashEntry,
    HotelCredit,
    OperationRecord,
    RoomAccounting
  }

  @dispositions ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  def fetch(payment_id, invalid_code) do
    case Repo.get_by(OperationRecord, operation_id: payment_id) do
      nil ->
        {:error, :operation_not_found}

      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, invalid_code}
    end
  end

  def statement(payment_id) do
    Repo.transact(fn ->
      with {:ok, payment} <- fetch(payment_id, :payment_not_reconcilable) do
        {:ok, summarize(payment, allocations(payment_id))}
      end
    end)
  end

  def fund(group, operation, occurred_on) do
    amount = operation["amount_cents"]
    {rooms, portions} = RoomAccounting.fund(group.rooms, amount, :cash_paid_cents)

    Enum.each(portions, fn {room_id, amount} ->
      AllocationOrder.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: operation["operation_id"],
        amount_cents: amount,
        held_cents: amount
      })
    end)

    CashEntry.record(group.group_id, operation, occurred_on, :payment, amount)
    Finance.record_cash(group.group_id, operation, occurred_on, :received, amount)
    rooms
  end

  def held_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in CashAllocation,
        where:
          allocation.group_id == ^group_id and allocation.room_id in ^room_ids and
            allocation.held_cents > 0,
        order_by: allocation.allocation_order
    )
  end

  def settle(allocations, settlement, lot, operation, occurred_on) do
    disposition =
      cond do
        settlement.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        settlement.retained_cents > 0 -> :retained_cents
        true -> :refunded_cents
      end

    if lot, do: HotelCredit.assign_entitlements(lot, allocations)

    Enum.each(allocations, fn allocation ->
      Finance.record_cash(
        allocation.group_id,
        operation,
        occurred_on,
        reporting_kind(disposition),
        allocation.held_cents
      )

      Repo.update!(
        change(allocation, %{
          disposition => Map.fetch!(allocation, disposition) + allocation.held_cents,
          :held_cents => 0
        })
      )
    end)
  end

  def reduce(group, payment, operation, occurred_on) do
    allocations = allocations(payment.operation_id)
    held = sum(allocations, :held_cents)
    amount = operation["amount_cents"]

    cond do
      held == 0 ->
        {:error, :payment_not_reducible}

      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_amount}

      amount > held ->
        {:error, :reduction_exceeds_held_cash}

      true ->
        portions = remove_held(allocations, amount, :reduced_cents)
        report_removed_cash(portions, operation, occurred_on, :reduced)
        CashEntry.record(group.group_id, operation, occurred_on, :reduction, amount)
        {:ok, portions}
    end
  end

  def charge_back(group, payment, operation, occurred_on) do
    allocations = allocations(payment.operation_id)
    remaining = payment.result["amount_cents"] - sum(allocations, :reduced_cents)

    if remaining == 0 or sum(allocations, :charged_back_cents) > 0 do
      {:error, :payment_not_chargeable}
    else
      portions = remove_held(allocations, sum(allocations, :held_cents), :charged_back_cents)
      report_removed_cash(portions, operation, occurred_on, :charged_back)

      # Held removal updated some rows; fetch their current balances before
      # reclassifying history so none of that removal is overwritten.
      Enum.each(allocations(payment.operation_id), fn allocation ->
        settled =
          allocation.refunded_cents + allocation.retained_cents +
            allocation.converted_to_credit_cents

        for field <- [:refunded_cents, :retained_cents, :converted_to_credit_cents] do
          Finance.record_cash(
            allocation.group_id,
            operation,
            occurred_on,
            reporting_kind(field),
            -Map.fetch!(allocation, field)
          )
        end

        Finance.record_cash(allocation.group_id, operation, occurred_on, :charged_back, settled)

        Repo.update!(
          change(allocation,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            charged_back_cents: allocation.charged_back_cents + settled
          )
        )
      end)

      for {field, kind} <- [
            refunded_cents: :refund,
            retained_cents: :retention,
            converted_to_credit_cents: :credit_conversion
          ] do
        CashEntry.record(group.group_id, operation, occurred_on, kind, -sum(allocations, field))
      end

      CashEntry.record(group.group_id, operation, occurred_on, :chargeback, remaining)
      HotelCredit.revoke_entitlements(payment.operation_id, operation, occurred_on)
      {:ok, portions, remaining}
    end
  end

  defp report_removed_cash(portions, operation, occurred_on, kind) do
    Enum.each(portions, fn {group_id, _room_id, amount} ->
      Finance.record_cash(group_id, operation, occurred_on, kind, amount)
    end)
  end

  defp reporting_kind(:refunded_cents), do: :refunded
  defp reporting_kind(:retained_cents), do: :retained
  defp reporting_kind(:converted_to_credit_cents), do: :converted_to_credit

  defp remove_held(allocations, amount, disposition) do
    {0, portions} =
      allocations
      |> Enum.reverse()
      |> Enum.reduce({amount, []}, fn allocation, {remaining, portions} ->
        removed = min(remaining, allocation.held_cents)

        if removed == 0 do
          {remaining, portions}
        else
          Repo.update!(
            change(allocation, %{
              disposition => Map.fetch!(allocation, disposition) + removed,
              :held_cents => allocation.held_cents - removed
            })
          )

          {remaining - removed, [{allocation.group_id, allocation.room_id, removed} | portions]}
        end
      end)

    portions
  end

  defp allocations(payment_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_id,
        order_by: allocation.allocation_order
    )
  end

  defp summarize(payment, allocations) do
    totals =
      Enum.reduce(
        @dispositions,
        %{
          payment_operation_id: payment.operation_id,
          original_group_id: payment.result["group_id"],
          recorded_cents: payment.result["amount_cents"]
        },
        fn field, totals -> Map.put(totals, field, sum(allocations, field)) end
      )

    if Enum.any?(allocations, & &1.transferred) do
      held_by_group =
        allocations
        |> Enum.filter(&(&1.held_cents > 0))
        |> Enum.group_by(& &1.group_id)
        |> Enum.sort_by(fn {group_id, _} -> group_id end)
        |> Enum.map(fn {group_id, held} ->
          %{group_id: group_id, amount_cents: sum(held, :held_cents)}
        end)

      Map.put(totals, :held_by_group, held_by_group)
    else
      totals
    end
  end

  defp sum(allocations, field), do: Enum.reduce(allocations, 0, &(&2 + Map.fetch!(&1, field)))
end
