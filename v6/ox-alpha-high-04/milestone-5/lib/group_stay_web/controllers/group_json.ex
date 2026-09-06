defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders the partner-facing representation of a group reservation.
  """

  def show(%{group: group}) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => GroupStay.policy_version(group.rate_plan, group.booked_on),
      "refundable_until" =>
        GroupStay.refundable_until(group.rate_plan, group.booked_on, group.arrival_on),
      "status" => group.status,
      "rooms" => Enum.map(group.rooms, &room/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => group.deposit_due_cents - group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents
    }
  end

  defp room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end
end
