defmodule GroupStay.Groups do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  def create_group!(attrs, rooms) do
    group = Repo.insert!(struct!(Group, attrs))

    rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

    %{group | rooms: rooms}
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: from(r in Room, order_by: r.position))
    end
  end

  def update_group!(group, fields) do
    group
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  def ledger_totals do
    %{
      "cash_held_cents" => sum_on_active(:deposit_paid_cents),
      "cash_refunded_cents" => Repo.aggregate(Group, :sum, :refunded_cents) || 0,
      "cash_retained_cents" => Repo.aggregate(Group, :sum, :retained_cents) || 0
    }
  end

  defp sum_on_active(field) do
    Repo.aggregate(from(g in Group, where: g.status == "active"), :sum, field) || 0
  end

  def to_json(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" => Enum.map(group.rooms, &room_json/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp room_json(room) do
    %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
  end

  defp outstanding(%{status: "cancelled"}), do: 0

  defp outstanding(group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end
end
