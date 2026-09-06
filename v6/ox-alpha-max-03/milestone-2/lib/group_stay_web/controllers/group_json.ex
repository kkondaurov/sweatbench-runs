defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group and its deposit totals.
  """

  alias GroupStay.Deposits
  alias GroupStay.Deposits.Group

  def show(%{group: group}) do
    %{data: data(group)}
  end

  defp data(%Group{} = group) do
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
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: Deposits.outstanding_deposit(group)
    }
  end

  defp refundable_until(%Group{} = group) do
    case Deposits.refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp room(room) do
    %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
  end
end
