defmodule GroupStay.RoomAccounting.Backfill do
  @moduledoc """
  One-time upgrade from aggregate funding to room allocations. Unattributed cash
  and credit form a senior block; retained inbox types and commit IDs identify the
  subsequent funding. Operation dates deliberately do not determine funding order.
  Cancelled groups retain their historical cash dispositions and lot entitlements.
  """
  import Ecto.Query
  alias GroupStay.{CashAllocation, RoomAccounting}
  alias GroupStay.Reservations.Group
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Operations.Record

  def run(repo) do
    records_by_group =
      repo.all(from r in Record, order_by: r.id)
      |> Enum.filter(&(&1.result["status"] == "applied"))
      |> Enum.group_by(& &1.result["group_id"])

    for group <- repo.all(Group) do
      records = Map.get(records_by_group, group.group_id, [])

      payments = Enum.filter(records, &(&1.type == "record_cash_payment"))
      cash = Group.cash_paid(group)
      legacy_cash = cash - Enum.sum(Enum.map(payments, & &1.result["amount_cents"]))

      if group.status == "active" do
        allocations =
          repo.all(from a in Allocation, where: a.group_id == ^group.group_id, order_by: a.id)

        repo.delete_all(from a in Allocation, where: a.group_id == ^group.group_id)
        RoomAccounting.fund_cash(group, nil, max(legacy_cash, 0), repo)

        recorded_credit =
          records
          |> Enum.filter(&(&1.type == "apply_hotel_credit"))
          |> Enum.map(& &1.result["amount_cents"])
          |> Enum.sum()

        queue = Enum.map(allocations, &{&1.lot_id, &1.amount_cents})

        queue =
          allocate_credit_queue(group, queue, group.credit_paid_cents - recorded_credit, repo)

        Enum.reduce(records, queue, fn record, queue ->
          case record.type do
            "record_cash_payment" ->
              RoomAccounting.fund_cash(
                group,
                record.operation_id,
                record.result["amount_cents"],
                repo
              )

              queue

            "apply_hotel_credit" ->
              allocate_credit_queue(group, queue, record.result["amount_cents"], repo)

            _ ->
              queue
          end
        end)

        RoomAccounting.refresh(group, repo)
      else
        disposition =
          cond do
            group.cash_converted_to_credit_cents > 0 -> "converted_to_credit"
            group.refunded_cents > 0 -> "refunded"
            true -> "retained"
          end

        blocks = [
          {nil, max(legacy_cash, 0)}
          | Enum.map(payments, &{&1.operation_id, &1.result["amount_cents"]})
        ]

        allocations =
          for {id, amount} <- blocks, amount > 0 do
            repo.insert!(%CashAllocation{
              group_id: group.group_id,
              payment_operation_id: id,
              amount_cents: amount,
              disposition: disposition
            })
          end

        cancellation = Enum.find(records, &(&1.type == "cancel_group"))

        if disposition == "converted_to_credit" and cancellation do
          lot = repo.get_by(Lot, source_operation_id: cancellation.operation_id)
          if lot, do: RoomAccounting.convert(allocations, lot.id, repo)
        end

        RoomAccounting.refresh(group, repo)
      end
    end
  end

  defp allocate_credit_queue(_group, queue, amount, _repo) when amount <= 0, do: queue
  defp allocate_credit_queue(_group, [], _amount, _repo), do: []

  defp allocate_credit_queue(group, [{lot, available} | rest], amount, repo) do
    used = min(available, amount)
    RoomAccounting.fund_credit(group, lot, used, repo)
    queue = if used == available, do: rest, else: [{lot, available - used} | rest]
    allocate_credit_queue(group, queue, amount - used, repo)
  end
end
