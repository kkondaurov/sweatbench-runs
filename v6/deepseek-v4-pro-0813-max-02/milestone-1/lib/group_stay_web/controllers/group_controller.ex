defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"group_id" => group_id}) do
    case Groups.fetch(group_id) do
      {:ok, %{group: group, rooms: rooms}} ->
        json(conn, %{data: serialize_group(group, rooms)})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end

  defp serialize_group(group, rooms) do
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
      rooms: Enum.map(rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp serialize_room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end

  defp outstanding(group) do
    case group.status do
      "cancelled" -> 0
      _ -> group.deposit_due_cents - group.deposit_paid_cents
    end
  end
end
