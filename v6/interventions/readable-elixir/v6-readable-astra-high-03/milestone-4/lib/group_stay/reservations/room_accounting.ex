defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Allocates deposits in original room order and projects held funding onto rooms.
  Cancelled rooms retain their original prices and requirement for support, but
  contribute nothing to group totals. Funding never moves between rooms when a
  room is cancelled or a payment is corrected.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.RoomFunding

  def fund(group, amount, source) do
    balances = balances(group)

    remaining =
      Enum.reduce(group.rooms, amount, fn room, remaining ->
        paid = Map.get(balances, room.room_id, %{cash: 0, credit: 0})

        capacity =
          if room.status == "active",
            do: room.deposit_due_cents - paid.cash - paid.credit,
            else: 0

        allocated = min(remaining, capacity)

        if allocated > 0 do
          Repo.insert!(
            struct!(
              RoomFunding,
              Map.merge(source, %{
                group_id: group.group_id,
                room_id: room.room_id,
                amount_cents: allocated
              })
            )
          )
        end

        remaining - allocated
      end)

    # The caller validates outstanding deposit before allocating any funding.
    0 = remaining
    :ok
  end

  def held(group),
    do: Repo.all(from f in RoomFunding, where: f.group_id == ^group.group_id, order_by: f.id)

  def changes(group, cancelled_ids \\ []) do
    balances = balances(group)

    rooms =
      Enum.map(group.rooms, fn room ->
        paid = Map.get(balances, room.room_id, %{cash: 0, credit: 0})

        %{
          room
          | status: if(room.room_id in cancelled_ids, do: "cancelled", else: room.status),
            cash_paid_cents: paid.cash,
            credit_paid_cents: paid.credit
        }
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    %{
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      deposit_paid_cents: cash + credit,
      credit_paid_cents: credit
    }
  end

  def remove(funding, amount) when amount == funding.amount_cents, do: Repo.delete!(funding)

  def remove(funding, amount),
    do:
      funding
      |> Ecto.Changeset.change(amount_cents: funding.amount_cents - amount)
      |> Repo.update!()

  defp balances(group) do
    Enum.reduce(held(group), %{}, fn funding, totals ->
      key = if funding.credit_lot_id, do: :credit, else: :cash

      Map.update(
        totals,
        funding.room_id,
        Map.put(%{cash: 0, credit: 0}, key, funding.amount_cents),
        fn paid ->
          Map.update!(paid, key, &(&1 + funding.amount_cents))
        end
      )
    end)
  end
end
