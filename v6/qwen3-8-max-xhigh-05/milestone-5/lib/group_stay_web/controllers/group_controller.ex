defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStay.Groups.Policy

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get_with_rooms(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: group_json(group)})
    end
  end

  defp group_json(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: Policy.version(group),
      refundable_until: refundable_until_json(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_json/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  defp room_json(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  defp refundable_until_json(group) do
    case Policy.refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp outstanding_deposit_cents(group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end
end
