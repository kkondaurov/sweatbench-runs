defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Funding
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy
  alias GroupStay.Groups.Room

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      %Group{} = group ->
        json(conn, %{data: group_json(group)})
    end
  end

  defp group_json(%Group{} = group) do
    room_paid = Funding.room_paid_map(Funding.held_for(group.id))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: Policy.refundable_until_iso(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_json(&1, room_paid)),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents - group.credit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp room_json(%Room{} = room, room_paid) do
    %{cash: cash, credit: credit} = Map.get(room_paid, room.room_id, %{cash: 0, credit: 0})

    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status || "active",
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    }
  end
end
