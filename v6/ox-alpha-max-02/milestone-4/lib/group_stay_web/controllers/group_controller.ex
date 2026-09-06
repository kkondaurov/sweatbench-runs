defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: group_payload(group)})
    end
  end

  defp group_payload(group) do
    totals = Groups.group_totals(group)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" =>
        case Groups.refundable_until(group) do
          nil -> nil
          date -> Date.to_iso8601(date)
        end,
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "status" => room.status,
            "lodging_cents" => room.lodging_cents,
            "deposit_due_cents" => room.deposit_due_cents,
            "cash_paid_cents" => room.cash_paid_cents,
            "credit_paid_cents" => room.credit_paid_cents
          }
        end),
      "lodging_total_cents" => totals.lodging_total_cents,
      "deposit_due_cents" => totals.deposit_due_cents,
      "deposit_paid_cents" => totals.deposit_paid_cents,
      "cash_paid_cents" => totals.cash_paid_cents,
      "credit_paid_cents" => totals.credit_paid_cents,
      "outstanding_deposit_cents" => totals.outstanding_deposit_cents
    }
  end
end
