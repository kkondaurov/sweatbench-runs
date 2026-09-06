defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group reservation and its totals for the partner API.
  """

  def group(%{group: group, rooms: rooms, totals: totals}) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" => Enum.map(rooms, &room/1)
    }
    |> Map.merge(totals_string_keys(totals))
  end

  defp room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "lodging_cents" => room.lodging_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end

  defp refundable_until(group) do
    case GroupStay.Groups.Group.refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp totals_string_keys(totals) do
    Map.new(totals, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
