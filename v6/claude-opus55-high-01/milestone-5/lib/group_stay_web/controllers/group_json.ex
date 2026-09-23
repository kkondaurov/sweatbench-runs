defmodule GroupStayWeb.GroupJSON do
  alias GroupStay.Groups.Group

  def show(%{group: group}), do: %{data: data(group)}

  defp data(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: Group.refundable_until(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: Group.cash_paid_cents(group),
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: Group.outstanding_deposit_cents(group)
    }
  end

  # A room's deposit is its share of the requirement while it is active. Its paid amounts are the
  # funding it currently holds, which settlement moves off a cancelled room.
  defp room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end
end
