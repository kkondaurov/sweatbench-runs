defmodule GroupStayWeb.GroupJSON do
  alias GroupStay.Reservations.Group

  def show(%{group: group}) do
    %{
      data: %{
        group_id: group.group_id,
        guest_id: group.guest_id,
        property_id: group.property_id,
        revision: group.revision,
        booked_on: group.booked_on,
        arrival_on: group.arrival_on,
        departure_on: group.departure_on,
        rate_plan: group.rate_plan,
        status: group.status,
        rooms: Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])),
        lodging_total_cents: group.lodging_total_cents,
        deposit_due_cents: group.deposit_due_cents,
        deposit_paid_cents: group.deposit_paid_cents,
        outstanding_deposit_cents: Group.outstanding_deposit(group)
      }
    }
  end
end
