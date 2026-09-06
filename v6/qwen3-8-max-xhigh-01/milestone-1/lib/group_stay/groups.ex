defmodule GroupStay.Groups do
  @moduledoc """
  Read-side access to group reservations and the finance totals derived from
  them.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner identifier, with rooms included.

  Returns `nil` when no group matches.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  @doc """
  Renders a group for the API, rooms in their original order, with derived
  totals.
  """
  def group_view(%Group{} = group) do
    rooms = Enum.sort_by(group.rooms, & &1.position)
    nights = nights(group)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + room.nightly_rate_cents * nights
      end)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end

  @doc """
  Cash totals across all groups.

  Cash currently applied to active groups is held; cancellation settles each
  group's cash as refunded or retained. Unpaid deposit requirements are not
  cash and never appear here.
  """
  def ledger_totals do
    %{
      cash_held_cents:
        sum_field(from(g in Group, where: g.status == "active"), :deposit_paid_cents),
      cash_refunded_cents:
        sum_field(from(g in Group, where: g.status == "cancelled"), :refunded_cents),
      cash_retained_cents:
        sum_field(from(g in Group, where: g.status == "cancelled"), :retained_cents)
    }
  end

  defp sum_field(query, field) do
    Repo.aggregate(query, :sum, field) || 0
  end

  defp nights(%Group{} = group) do
    Date.diff(group.departure_on, group.arrival_on)
  end
end
