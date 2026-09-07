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
          order_by: a.allocation_order
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

          allocation |> Ecto.Changeset.change(allocation_order: next_order()) |> Repo.insert!()
        end

        if remaining == used, do: {:halt, 0}, else: {:cont, remaining - used}
      end)
  end

  # Both allocation tables share a sequence. Writes are serialized by the
  # operation transaction; retained rows keep their order when partially drawn.
  defp next_order do
    cash = Repo.one(from a in CashAllocation, select: coalesce(max(a.allocation_order), 0))
    credit = Repo.one(from a in CreditAllocation, select: coalesce(max(a.allocation_order), 0))
    max(cash, credit) + 1
  end

  def held_funding(group_id) do
    credit = Repo.all(from a in CreditAllocation, where: a.group_id == ^group_id)
    Enum.sort_by(held_cash(group_id) ++ credit, & &1.allocation_order, :desc)
  end

  def transfer(source, destination, amount) do
    Enum.reduce_while(held_funding(source.group_id), amount, fn row, remaining ->
      moved = min(row.amount_cents, remaining)

      if moved == row.amount_cents do
        Repo.delete!(row)
      else
        row |> Ecto.Changeset.change(amount_cents: row.amount_cents - moved) |> Repo.update!()
      end

      case row do
        %CashAllocation{} ->
          if row.payment_operation_id do
            Repo.insert_all(
              "transferred_payments",
              [%{payment_operation_id: row.payment_operation_id}],
              on_conflict: :nothing
            )
          end

          fund(destination, moved, :cash, row.payment_operation_id)

        %CreditAllocation{} ->
          fund(destination, moved, :credit, row.operation_id, row.credit_lot_id)
      end

      if moved == remaining, do: {:halt, 0}, else: {:cont, remaining - moved}
    end)
  end

  def refresh_other_groups(group_ids, addressed_id) do
    group_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == addressed_id))
    |> Enum.each(fn id ->
      group = Repo.get!(GroupStay.Reservations.Group, id)

      group
      |> Ecto.Changeset.change(Map.put(totals(group), :revision, group.revision + 1))
      |> Repo.update!()
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
