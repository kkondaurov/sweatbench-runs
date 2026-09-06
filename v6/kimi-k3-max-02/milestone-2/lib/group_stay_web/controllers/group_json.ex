defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group reservation as returned by the partner read endpoint.
  """

  alias GroupStay.Groups
  alias GroupStay.Groups.{Group, Room}

  def data(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_string(group.booked_on),
      arrival_on: Date.to_string(group.arrival_on),
      departure_on: Date.to_string(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: format_date(Groups.refundable_until(group)),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_data/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp room_data(%Room{} = room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_string(date)
end
