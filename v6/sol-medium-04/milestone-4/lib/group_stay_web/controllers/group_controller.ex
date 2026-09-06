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
            policy_version: group.policy_version,
            refundable_until: Operations.refundable_until(group),
            status: group.status,
            rooms:
              Enum.map(
                group.rooms,
                fn room ->
                  cash = Enum.sum(Enum.map(room.cash_allocations, & &1.amount_cents))
                  credit = Enum.sum(Enum.map(room.credit_applications, & &1.amount_cents))

                  %{
                    room_id: room.room_id,
                    nightly_rate_cents: room.nightly_rate_cents,
                    status: room.status,
                    lodging_total_cents: room.lodging_total_cents,
                    deposit_due_cents: room.deposit_due_cents,
                    cash_paid_cents: cash,
                    credit_paid_cents: credit
                  }
                end
              ),
            lodging_total_cents: group.lodging_total_cents,
            deposit_due_cents: group.deposit_due_cents,
            deposit_paid_cents: group.deposit_paid_cents,
            cash_paid_cents: group.cash_paid_cents,
            credit_paid_cents: group.credit_paid_cents,
            outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
          }
        })
    end
  end
end
