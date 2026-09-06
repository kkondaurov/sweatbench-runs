defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group, its rooms with their room-level accounting, and the
  deposit totals describing its active rooms.
  """

  alias GroupStay.Deposits
  alias GroupStay.Deposits.Group

  def show(%{group: group}) do
    %{data: data(Deposits.with_room_accounting(group))}
  end

  defp data(%Group{} = group) do
    totals = Deposits.group_totals(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      rooms: Enum.map(group.rooms, &room/1),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end

  defp refundable_until(%Group{} = group) do
    case Deposits.refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_amount_cents: room.lodging_amount_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end
end
