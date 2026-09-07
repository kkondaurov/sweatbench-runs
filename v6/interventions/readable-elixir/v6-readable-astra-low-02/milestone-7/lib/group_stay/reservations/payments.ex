defmodule GroupStay.Reservations.Payments do
  @moduledoc """
  Cash reconciliation, provider reductions, and chargebacks.

  Cash rows partition each recorded payment into exactly one current disposition.
  Credit entitlement records are separate: credit is fungible within a lot, so a
  chargeback revokes entitlement without attributing redemptions to payments.
  """
  import Ecto.Query
  alias GroupStay.{Operations, Repo}

  alias GroupStay.Reservations.{
    CashAllocation,
    HotelCredit,
    RoomAccounting
  }

  @dispositions [
    {"held", :held_cents, :cash_held_cents},
    {"refunded", :refunded_cents, :cash_refunded_cents},
    {"retained", :retained_cents, :cash_retained_cents},
    {"converted_to_credit", :converted_to_credit_cents, :cash_converted_to_credit_cents},
    {"reduced", :reduced_cents, :cash_reduced_cents},
    {"charged_back", :charged_back_cents, :cash_charged_back_cents}
  ]

  def target!(id, error) do
    record = Repo.get_by(Operations, operation_id: id) || reject("operation_not_found")

    unless record.type == "record_cash_payment" and record.result["status"] == "applied",
      do: reject(error)

    record
  end

  def statement(id) do
    {:ok, result} = Repo.transaction(fn -> read_statement(id) end)
    result
  end

  defp read_statement(id) do
    case Repo.get_by(Operations, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      %{type: "record_cash_payment", result: %{"status" => "applied"}} = record ->
        rows = allocations(id)
        totals = disposition_totals(rows)

        totals =
          if Repo.exists?(from p in "transferred_payments", where: p.payment_operation_id == ^id) do
            held_by_group =
              rows
              |> Enum.filter(&(&1.disposition == "held"))
              |> Enum.group_by(& &1.group_id)
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.map(fn {group_id, held} ->
                %{group_id: group_id, amount_cents: Enum.sum(Enum.map(held, & &1.amount_cents))}
              end)

            Map.put(totals, :held_by_group, held_by_group)
          else
            totals
          end

        {:ok,
         Map.merge(totals, %{
           payment_operation_id: id,
           original_group_id: record.result["group_id"],
           recorded_cents: record.result["amount_cents"]
         })}

      _ ->
        {:error, "payment_not_reconcilable"}
    end
  end

  def ledger do
    totals =
      Repo.all(
        from a in CashAllocation,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(@dispositions, fn {disposition, _, ledger_key} ->
      {ledger_key, Map.get(totals, disposition, 0)}
    end)
  end

  defp disposition_totals(rows) do
    Map.new(@dispositions, fn {disposition, key, _} ->
      {key,
       rows
       |> Enum.filter(&(&1.disposition == disposition))
       |> Enum.map(& &1.amount_cents)
       |> Enum.sum()}
    end)
  end

  defp allocations(id),
    do:
      Repo.all(
        from a in CashAllocation,
          where: a.payment_operation_id == ^id,
          order_by: a.allocation_order
      )

  def reduce(group, id, amount) do
    held = Enum.filter(allocations(id), &(&1.disposition == "held"))
    total = Enum.sum(Enum.map(held, & &1.amount_cents))
    if total == 0, do: reject("payment_not_reducible")
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > total, do: reject("reduction_exceeds_held_cash")

    changed_groups =
      Enum.reduce_while(Enum.reverse(held), {amount, []}, fn row, {remaining, groups} ->
        removed = min(row.amount_cents, remaining)
        move(row, removed, "reduced")
        groups = [row.group_id | groups]
        if removed == remaining, do: {:halt, groups}, else: {:cont, {remaining - removed, groups}}
      end)

    RoomAccounting.refresh_other_groups(changed_groups, group.group_id)
    totals = RoomAccounting.totals(group)

    {totals,
     %{
       payment_operation_id: id,
       amount_cents: amount,
       outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents
     }}
  end

  def charge_back(group, id, on) do
    rows = allocations(id)
    remaining = Enum.reject(rows, &(&1.disposition in ["reduced", "charged_back"]))
    amount = Enum.sum(Enum.map(remaining, & &1.amount_cents))

    if amount == 0 or Enum.any?(rows, &(&1.disposition == "charged_back")),
      do: reject("payment_not_chargeable")

    for row <- Enum.reverse(remaining), do: move(row, row.amount_cents, "charged_back")

    remaining
    |> Enum.filter(&(&1.disposition == "held"))
    |> Enum.map(& &1.group_id)
    |> RoomAccounting.refresh_other_groups(group.group_id)

    HotelCredit.revoke_payment(id, on)

    totals = RoomAccounting.totals(group)

    {totals,
     %{
       payment_operation_id: id,
       charged_back_cents: amount,
       outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents
     }}
  end

  def settle(rows, disposition) do
    for row <- rows, do: move(row, row.amount_cents, disposition)
  end

  defp move(row, amount, disposition) when amount == row.amount_cents,
    do: row |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()

  defp move(row, amount, disposition) do
    row |> Ecto.Changeset.change(amount_cents: row.amount_cents - amount) |> Repo.update!()

    Repo.insert!(%CashAllocation{
      allocation_order: row.allocation_order,
      group_id: row.group_id,
      room_id: row.room_id,
      payment_operation_id: row.payment_operation_id,
      amount_cents: amount,
      disposition: disposition
    })
  end

  defp reject(code), do: Operations.reject(%{code: code})
end
