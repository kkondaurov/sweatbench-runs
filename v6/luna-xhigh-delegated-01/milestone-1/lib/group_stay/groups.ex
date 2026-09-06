defmodule GroupStay.Groups do
  @moduledoc "Persistence and read operations for group reservations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"

  def get(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        %{
          group
          | rooms:
              Repo.all(
                from room in Room, where: room.group_id == ^group_id, order_by: room.position
              )
        }
    end
  end

  def get(_group_id), do: nil

  def active?(%Group{status: @active}), do: true
  def active?(_group), do: false

  def active_status, do: @active
  def cancelled_status, do: @cancelled

  def serialize(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(group.rooms || [], fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: max(group.deposit_due_cents - group.deposit_paid_cents, 0)
    }
  end
end
