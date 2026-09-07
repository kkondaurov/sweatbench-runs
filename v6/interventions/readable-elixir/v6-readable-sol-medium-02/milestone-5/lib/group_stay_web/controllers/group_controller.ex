defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStay.Reservations.CancellationPolicy

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: serialize(group)})

      {:error, :group_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end

  defp serialize(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: CancellationPolicy.version(group),
      refundable_until: CancellationPolicy.refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: Reservations.outstanding_deposit(group)
    }
  end
end
