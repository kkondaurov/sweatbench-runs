defmodule GroupStay.Reservations.Payments do
  @moduledoc """
  Reconciles durable cash payments and corrects their current dispositions.
  Original journal results are immutable; allocations are the current accounting
  facts. Revision validation is performed by Reservations before these mutations.
  Corrections save each secondary group once and return the original group's
  changes to Reservations, which saves that addressed group and its revision.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Operations.Record}
  alias GroupStay.Reservations.{CashAllocation, HotelCredit, RoomAccounting, Group}

  @dispositions [
    held_cents: "held",
    refunded_cents: "refunded",
    retained_cents: "retained",
    converted_to_credit_cents: "converted_to_credit",
    reduced_cents: "reduced",
    charged_back_cents: "charged_back"
  ]

  def target(payment_id) do
    case Repo.get_by(Record, operation_id: payment_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        {:ok, record}

      _ ->
        {:error, "not_payment"}
    end
  end

  def statement(payment_id) do
    {:ok, result} = Repo.transaction(fn -> read_statement(payment_id) end)
    result
  end

  defp read_statement(payment_id) do
    case target(payment_id) do
      {:ok, record} ->
        statement =
          Map.merge(dispositions(payment_id), %{
            payment_operation_id: payment_id,
            original_group_id: record.result["group_id"],
            recorded_cents: record.result["amount_cents"]
          })

        transferred? =
          Repo.exists?(
            from p in "transferred_payments", where: p.payment_operation_id == ^payment_id
          )

        statement =
          if transferred?,
            do: Map.put(statement, :held_by_group, held_by_group(payment_id)),
            else: statement

        {:ok, statement}

      {:error, "not_payment"} ->
        {:error, "payment_not_reconcilable"}

      error ->
        error
    end
  end

  def dispositions(payment_id) do
    totals =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_operation_id == ^payment_id,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(@dispositions, fn {field, disposition} ->
      {field, Map.get(totals, disposition, 0)}
    end)
  end

  def reduce(group, payment_id, amount) do
    held = held(payment_id)
    total = Enum.sum(Enum.map(held, & &1.amount_cents))

    cond do
      total == 0 ->
        {:error, "payment_not_reducible"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > total ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        rooms = remove_held(group, held, amount, "reduced")
        changes = RoomAccounting.changes(rooms)

        {:ok, changes,
         %{
           payment_operation_id: payment_id,
           amount_cents: amount,
           outstanding_deposit_cents: Group.outstanding(Map.merge(group, changes))
         }}
    end
  end

  def charge_back(group, payment_id, on) do
    totals = dispositions(payment_id)

    amount =
      totals.held_cents + totals.refunded_cents + totals.retained_cents +
        totals.converted_to_credit_cents

    if totals.charged_back_cents > 0 or amount == 0 do
      {:error, "payment_not_chargeable"}
    else
      rooms =
        remove_held(
          group,
          held(payment_id),
          totals.held_cents,
          "charged_back"
        )

      for allocation <-
            Repo.all(
              from a in CashAllocation,
                where:
                  a.payment_operation_id == ^payment_id and
                    a.disposition in ["refunded", "retained", "converted_to_credit"]
            ) do
        RoomAccounting.move(allocation, allocation.amount_cents, "charged_back")
      end

      HotelCredit.revoke(payment_id, on)
      changes = RoomAccounting.changes(rooms)

      {:ok, changes,
       %{
         payment_operation_id: payment_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding(Map.merge(group, changes))
       }}
    end
  end

  defp held_by_group(payment_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_id and a.disposition == "held",
        group_by: a.group_id,
        order_by: a.group_id,
        select: %{group_id: a.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  # Select globally before grouping, so corrections unwind the newest slices
  # even when a payment has travelled through several reservations.
  defp remove_held(original, allocations, amount, disposition) do
    {selected, 0} =
      Enum.map_reduce(allocations, amount, fn allocation, remaining ->
        used = min(remaining, allocation.amount_cents)
        {{allocation, used}, remaining - used}
      end)

    selected
    |> Enum.filter(fn {_, used} -> used > 0 end)
    |> Enum.group_by(fn {allocation, _} -> allocation.group_id end)
    |> Enum.reduce(original.rooms, fn {group_id, slices}, original_rooms ->
      group = if group_id == original.group_id, do: original, else: Repo.get!(Group, group_id)

      rooms =
        Enum.reduce(slices, group.rooms, fn {allocation, used}, rooms ->
          RoomAccounting.remove_cash(rooms, [allocation], used, disposition)
        end)

      if group_id == original.group_id do
        rooms
      else
        group
        |> Ecto.Changeset.change(
          Map.put(RoomAccounting.changes(rooms), :revision, group.revision + 1)
        )
        |> Repo.update!()

        original_rooms
      end
    end)
  end

  defp held(payment_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_id and a.disposition == "held",
        order_by: [desc: a.allocation_order]
    )
  end
end
