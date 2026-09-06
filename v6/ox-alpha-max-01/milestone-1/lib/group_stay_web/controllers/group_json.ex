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
      "status" => group.status,
      "rooms" =>
        Enum.map(rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end)
    }
    |> Map.merge(totals_string_keys(totals))
  end

  defp totals_string_keys(totals) do
    Map.new(totals, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
