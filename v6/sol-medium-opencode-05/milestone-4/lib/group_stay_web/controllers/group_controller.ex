defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: serialize(group)})
    end
  end

  defp serialize(group) do
    totals = Operations.group_totals(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: Operations.policy_version(group),
      refundable_until: Operations.refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          amounts = Operations.room_amounts(room)

          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: amounts.cash_paid_cents,
            credit_paid_cents: amounts.credit_paid_cents
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end
end
