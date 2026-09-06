defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{
          data: %{
            group_id: group.id,
            guest_id: group.guest_id,
            property_id: group.property_id,
            revision: group.revision,
            booked_on: group.booked_on,
            arrival_on: group.arrival_on,
            departure_on: group.departure_on,
            rate_plan: group.rate_plan,
            status: group.status,
            rooms:
              Enum.map(
                group.rooms,
                &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}
              ),
            lodging_total_cents: group.lodging_total_cents,
            deposit_due_cents: group.deposit_due_cents,
            deposit_paid_cents: group.deposit_paid_cents,
            outstanding_deposit_cents:
              if(group.status == "active",
                do: group.deposit_due_cents - group.deposit_paid_cents,
                else: 0
              )
          }
        })
    end
  end
end
