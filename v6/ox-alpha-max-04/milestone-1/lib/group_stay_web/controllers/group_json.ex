defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group reservation and its deposit totals for the read endpoint.
  """

  alias GroupStay.Groups.Group

  def show(%Group{} = group) do
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
      rooms: Enum.map(group.rooms, &room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid(group),
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end

  defp deposit_paid(%Group{status: "active"} = group), do: group.cash_paid_cents
  defp deposit_paid(%Group{}), do: 0

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.cash_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
end
