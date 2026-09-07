defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Ordered room deposit funding. Allocations are never redistributed when a room
  is cancelled or a payment corrected: only new funding fills reopened space.
  All writes participate in the caller's durable-operation transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation}

  def rooms(group) do
    cash = held_cash(group.group_id)
    credit = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(group.rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights
      due = if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      status = Map.get(room, "status", group.status)

      Map.merge(room, %{
        "status" => status,
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => if(status == "active", do: due, else: 0),
        "cash_paid_cents" => sum_room(cash, room["room_id"]),
        "credit_paid_cents" => sum_room(credit, room["room_id"])
      })
    end)
  end

  defp sum_room(allocations, id),
    do:
      allocations |> Enum.filter(&(&1.room_id == id)) |> Enum.map(& &1.amount_cents) |> Enum.sum()

  def held_cash(group_id),
    do:
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group_id and a.disposition == "held",
          order_by: a.id
      )

  def fund(group, amount, kind, source_id, lot_id \\ nil) do
    0 =
      Enum.reduce_while(rooms(group), amount, fn room, remaining ->
        space = room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
        used = min(remaining, max(space, 0))

        if used > 0 do
          allocation =
            case kind do
              :cash ->
                %CashAllocation{
                  group_id: group.group_id,
                  room_id: room["room_id"],
                  payment_operation_id: source_id,
                  amount_cents: used
                }

              :credit ->
                %CreditAllocation{
                  group_id: group.group_id,
                  room_id: room["room_id"],
                  operation_id: source_id,
                  credit_lot_id: lot_id,
                  amount_cents: used
                }
            end

          Repo.insert!(allocation)
        end

        if remaining == used, do: {:halt, 0}, else: {:cont, remaining - used}
      end)
  end

  def totals(group) do
    active = Enum.filter(rooms(group), &(&1["status"] == "active"))
    sum = fn key -> Enum.sum(Enum.map(active, & &1[key])) end

    %{
      lodging_total_cents: sum.("lodging_total_cents"),
      deposit_due_cents: sum.("deposit_due_cents"),
      deposit_paid_cents: sum.("cash_paid_cents") + sum.("credit_paid_cents"),
      credit_paid_cents: sum.("credit_paid_cents")
    }
  end

  def cancel(group, ids) do
    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in ids, do: Map.put(room, "status", "cancelled"), else: room
      end)

    updated = %{group | rooms: rooms}

    status =
      if Enum.all?(rooms(updated), &(&1["status"] == "cancelled")),
        do: "cancelled",
        else: "active"

    Map.merge(totals(updated), %{rooms: rooms, status: status})
  end
end
