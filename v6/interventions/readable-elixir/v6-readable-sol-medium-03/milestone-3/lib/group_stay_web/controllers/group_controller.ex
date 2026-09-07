defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits
  alias GroupStay.Deposits.Policy

  def show(conn, %{"group_id" => group_id}) do
    case Deposits.get_group(group_id) do
      {:ok, group} -> json(conn, %{data: group_json(group)})
      {:error, :group_not_found} -> not_found(conn)
    end
  end

  defp group_json(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: Policy.refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: Deposits.outstanding_deposit(group)
    }
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "group_not_found"}})
  end
end
