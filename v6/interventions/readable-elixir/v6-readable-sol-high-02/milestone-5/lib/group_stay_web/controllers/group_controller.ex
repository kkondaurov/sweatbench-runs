defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStay.Reservations.{CancellationPolicy, Group}

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "group_not_found"}})

      group ->
        json(conn, %{"data" => render_group(group)})
    end
  end

  defp render_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => Atom.to_string(group.rate_plan),
      "policy_version" => CancellationPolicy.external_name(group.policy_version),
      "refundable_until" => format_date(Group.refundable_until(group)),
      "status" => Atom.to_string(group.status),
      "rooms" => Enum.map(group.rooms, &render_room/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => Group.outstanding_deposit_cents(group)
    }
  end

  defp render_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "lodging_total_cents" => room.lodging_total_cents,
      "status" => Atom.to_string(room.status),
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)
end
