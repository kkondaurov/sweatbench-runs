defmodule GroupStay.RoomAccounting do
  @moduledoc "Room funding and cash dispositions, written within the partner operation transaction."
  import Ecto.Query
  alias GroupStay.{CashAllocation, CreditAllocation, CreditEntitlement, CreditLot, Repo}
  alias GroupStay.FinanceReporting

  def price(room, nights, plan, status \\ "active") do
    lodging = room["nightly_rate_cents"] * nights
    due = if plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

    Map.merge(room, %{
      "status" => status,
      "lodging_total_cents" => if(status == "active", do: lodging, else: 0),
      "deposit_due_cents" => if(status == "active", do: due, else: 0),
      "cash_paid_cents" => 0,
      "credit_paid_cents" => 0
    })
  end

  def fund(group, amount, kind, operation_id, lot_id \\ nil, transferred \\ false) do
    {rooms, 0} =
      Enum.map_reduce(group.rooms, amount, fn room, needed ->
        free = room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
        used = if room["status"] == "active", do: min(free, needed), else: 0

        if used > 0 do
          if kind == :cash do
            Repo.insert!(%CashAllocation{
              group_id: group.group_id,
              room_id: room["room_id"],
              payment_operation_id: operation_id,
              allocation_order: next_order(),
              transferred: transferred,
              amount_cents: used
            })
          else
            Repo.insert!(%CreditAllocation{
              group_id: group.group_id,
              room_id: room["room_id"],
              operation_id: operation_id,
              credit_lot_id: lot_id,
              allocation_order: next_order(),
              amount_cents: used
            })
          end
        end

        field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"
        {Map.update!(room, field, &(&1 + used)), needed - used}
      end)

    %{group | rooms: rooms}
  end

  # One transactional sequence orders both funding kinds, including new placements
  # created by transfers. Splitting settled cash preserves the original placement order.
  defp next_order do
    %{rows: [[order]]} =
      Repo.query!("UPDATE allocation_sequence SET value = value + 1 RETURNING value")

    order
  end

  def transfer(source, destination, amount) do
    allocations =
      (Repo.all(
         from a in CashAllocation,
           where: a.group_id == ^source.group_id and a.disposition == "held"
       ) ++
         Repo.all(from a in CreditAllocation, where: a.group_id == ^source.group_id))
      |> Enum.sort_by(& &1.allocation_order, :desc)

    {source, destination, 0} =
      Enum.reduce(allocations, {source, destination, amount}, fn allocation,
                                                                 {source, destination, left} ->
        used = min(left, allocation.amount_cents)

        if used == 0 do
          {source, destination, left}
        else
          if used == allocation.amount_cents,
            do: Repo.delete!(allocation),
            else: change(allocation, %{amount_cents: allocation.amount_cents - used})

          destination =
            case allocation do
              %CashAllocation{} ->
                fund(destination, used, :cash, allocation.payment_operation_id, nil, true)

              %CreditAllocation{} ->
                fund(
                  destination,
                  used,
                  :credit,
                  allocation.operation_id,
                  allocation.credit_lot_id
                )
            end

          source = %{source | rooms: remove_held(source.rooms, allocation, used)}
          {source, destination, left - used}
        end
      end)

    {source, destination}
  end

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1["status"] == "active"))
    sum = fn field -> Enum.sum(Enum.map(active, & &1[field])) end
    cash = sum.("cash_paid_cents")
    credit = sum.("credit_paid_cents")

    %{
      rooms: rooms,
      lodging_total_cents: sum.("lodging_total_cents"),
      deposit_due_cents: sum.("deposit_due_cents"),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      status: if(active == [], do: "cancelled", else: "active")
    }
  end

  def cash(group_id, room_ids) do
    Repo.all(
      from a in CashAllocation,
        where: a.group_id == ^group_id and a.room_id in ^room_ids and a.disposition == "held",
        order_by: a.allocation_order
    )
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def entitle(lot, allocations) do
    # A payment can span rooms. Aggregate before rounding, preserving funding order.
    {order, amounts} =
      Enum.reduce(allocations, {[], %{}}, fn a, {order, amounts} ->
        id = a.payment_operation_id

        {if(Map.has_key?(amounts, id), do: order, else: order ++ [id]),
         Map.update(amounts, id, a.amount_cents, &(&1 + a.amount_cents))}
      end)

    Enum.reduce(order, 0, fn id, preceding ->
      through = preceding + amounts[id]

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: id,
        amount_cents: bonus_value(through) - bonus_value(preceding)
      })

      through
    end)
  end

  def restore(allocation, on, op) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

    available =
      if Date.compare(lot.expires_on, on) == :lt,
        do: 0,
        else: allocation.amount_cents - absorbed

    change(lot, %{
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + available
    })

    FinanceReporting.credit_change(
      op,
      lot,
      available,
      -allocation.amount_cents,
      :absorbed,
      absorbed
    )
  end

  def revoke(payment_id, op) do
    for entitlement <-
          Repo.all(
            from e in CreditEntitlement,
              where: e.payment_operation_id == ^payment_id,
              order_by: e.id
          ) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      change(lot, %{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      })

      FinanceReporting.credit_change(op, lot, -removed, 0, :revoked, removed)
    end
  end

  def shortfall do
    Repo.all(
      from l in CreditLot,
        left_join: a in CreditAllocation,
        on: a.credit_lot_id == l.id,
        group_by: l.id,
        select: {l.unrecovered_clawback_cents, coalesce(sum(a.amount_cents), 0)}
    )
    |> Enum.map(fn {clawback, applied} -> min(clawback, applied) end)
    |> Enum.sum()
  end

  def payment_allocations(id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^id,
        order_by: [desc: a.allocation_order]
    )
  end

  def move(allocation, amount, disposition) do
    if amount == allocation.amount_cents do
      change(allocation, %{disposition: disposition})
    else
      change(allocation, %{amount_cents: allocation.amount_cents - amount})

      Repo.insert!(%CashAllocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        allocation_order: allocation.allocation_order,
        transferred: allocation.transferred,
        amount_cents: amount,
        disposition: disposition
      })
    end
  end

  def remove_held(rooms, allocation, amount) do
    field =
      if match?(%CashAllocation{}, allocation), do: "cash_paid_cents", else: "credit_paid_cents"

    Enum.map(rooms, fn room ->
      if room["room_id"] == allocation.room_id,
        do: Map.update!(room, field, &(&1 - amount)),
        else: room
    end)
  end

  def change(record, fields), do: record |> Ecto.Changeset.change(fields) |> Repo.update!()
end
