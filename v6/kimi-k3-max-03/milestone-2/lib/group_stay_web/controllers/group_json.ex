defmodule GroupStayWeb.GroupJSON do
  @moduledoc false

  def render("show.json", %{group: group}) do
    %{data: serialize(group)}
  end

  def render("not_found.json", _assigns) do
    %{error: %{code: "group_not_found"}}
  end

  defp serialize(group) do
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
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  # Cancellation settles the deposit: whatever was not paid is no longer due.
  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end
end
