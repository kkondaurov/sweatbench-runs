defmodule GroupStayWeb.GroupJSON do
  @moduledoc "Renders a group reservation for partner reads."

  alias GroupStay.Reservations.Group

  def show(%{group: group}), do: %{data: data(group)}

  def data(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms: Enum.map(group.rooms, &room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: Group.outstanding_deposit_cents(group)
    }
  end

  defp room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end
end
