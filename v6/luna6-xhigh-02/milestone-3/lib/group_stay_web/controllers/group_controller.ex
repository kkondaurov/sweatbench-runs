defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  def show(conn, %{"group_id" => group_id}) do
    case GroupStay.Groups.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      {group, rooms} ->
        policy = GroupStay.Groups.cancellation_policy(group)

        outstanding =
          if group.status == "active" do
            group.deposit_due_cents - group.deposit_paid_cents
          else
            0
          end

        data = %{
          group_id: group.group_id,
          guest_id: group.guest_id,
          property_id: group.property_id,
          revision: group.revision,
          booked_on: Date.to_iso8601(group.booked_on),
          arrival_on: Date.to_iso8601(group.arrival_on),
          departure_on: Date.to_iso8601(group.departure_on),
          rate_plan: group.rate_plan,
          policy_version: policy.policy_version,
          refundable_until: policy.refundable_until,
          status: group.status,
          rooms:
            Enum.map(rooms, fn room ->
              %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
            end),
          lodging_total_cents: group.lodging_total_cents,
          deposit_due_cents: group.deposit_due_cents,
          deposit_paid_cents: group.deposit_paid_cents,
          cash_paid_cents: group.cash_paid_cents,
          credit_paid_cents: group.credit_paid_cents,
          outstanding_deposit_cents: outstanding
        }

        json(conn, %{data: data})
    end
  end
end
