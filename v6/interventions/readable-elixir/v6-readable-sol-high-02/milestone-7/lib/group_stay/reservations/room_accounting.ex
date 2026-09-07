defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Maintains the active-room projection used by group reads and payment validation.

  Room requirements never change after opening. Cancelling a room removes its requirement and
  funding from group totals while preserving those original room amounts for support reads.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  def active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == :active,
        order_by: room.position
    )
  end

  def selected_active_rooms(group_id, room_ids) do
    Repo.all(
      from room in Room,
        where:
          room.group_id == ^group_id and room.status == :active and room.room_id in ^room_ids,
        order_by: room.position
    )
  end

  def totals(group_id) do
    active = active_rooms(group_id)

    %{
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      cash_paid_cents: Enum.sum(Enum.map(active, & &1.cash_paid_cents)),
      credit_paid_cents: Enum.sum(Enum.map(active, & &1.credit_paid_cents)),
      deposit_paid_cents:
        Enum.sum(Enum.map(active, &(&1.cash_paid_cents + &1.credit_paid_cents))),
      status: if(active == [], do: :cancelled, else: :active)
    }
  end

  def fund_room(room, cash_delta, credit_delta) do
    room
    |> Room.funding_changeset(cash_delta, credit_delta)
    |> Repo.update!()
  end

  def cancel_room(room) do
    room
    |> Room.cancellation_changeset()
    |> Repo.update!()
  end

  def update_group(group, extra_attrs \\ %{}) do
    attrs = group.group_id |> totals() |> Map.merge(extra_attrs)

    group
    |> Group.accounting_changeset(attrs)
    |> Repo.update()
  end
end
