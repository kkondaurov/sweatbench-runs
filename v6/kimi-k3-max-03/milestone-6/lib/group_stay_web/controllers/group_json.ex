defmodule GroupStayWeb.GroupJSON do
  @moduledoc false

  def render("show.json", %{group: group}) do
    %{data: serialize(group)}
  end

  def render("not_found.json", _assigns) do
    %{error: %{code: "group_not_found"}}
  end

  defp serialize(group) do
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))
    nights = Date.diff(group.departure_on, group.arrival_on)

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
      policy_version: group.policy_version,
      refundable_until: group.refundable_until,
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: Enum.sum_by(active_rooms, &(&1.nightly_rate_cents * nights)),
      deposit_due_cents: Enum.sum_by(active_rooms, & &1.deposit_due_cents),
      deposit_paid_cents: paid_cents(active_rooms),
      cash_paid_cents: Enum.sum_by(active_rooms, & &1.cash_paid_cents),
      credit_paid_cents: Enum.sum_by(active_rooms, & &1.credit_paid_cents),
      outstanding_deposit_cents: outstanding(active_rooms)
    }
  end

  # Cancellation settles the deposit: whatever was not paid is no longer due.
  defp outstanding(active_rooms) do
    Enum.sum_by(active_rooms, fn room ->
      room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    end)
  end

  defp paid_cents(active_rooms) do
    Enum.sum_by(active_rooms, &(&1.cash_paid_cents + &1.credit_paid_cents))
  end

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end
end
