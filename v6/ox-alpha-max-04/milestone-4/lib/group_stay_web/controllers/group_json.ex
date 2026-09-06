defmodule GroupStayWeb.GroupJSON do
  @moduledoc """
  Renders a group reservation, its cancellation policy, its rooms with their
  own deposit figures, and the group totals. The group's lodging, due, paid,
  and outstanding totals describe active rooms only; a cancelled room's
  unpaid deposit is no longer due and nothing is paid on it.
  """

  alias GroupStay.Accounting
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy

  def show(%Group{} = group) do
    state = Accounting.replay(group)
    figures = Map.new(state.rooms, &{&1.room_id, Accounting.room_figures(&1)})

    rooms =
      Enum.map(group.rooms, fn room ->
        figure = figures[room.room_id]

        if room.status == "active" and figure.active do
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: "active",
            deposit_due_cents: figure.due,
            cash_paid_cents: figure.cash,
            credit_paid_cents: figure.credit
          }
        else
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: "cancelled",
            deposit_due_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end
      end)

    active_figures =
      group.rooms
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(&figures[&1.room_id])
      |> Enum.filter(&(&1 && &1.active))

    nights = Date.diff(group.departure_on, group.arrival_on)

    lodging_total =
      group.rooms
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&(figures[&1.room_id] && figures[&1.room_id].active))
      |> Enum.reduce(0, &(&1.nightly_rate_cents * nights + &2))

    due_total = Enum.reduce(active_figures, 0, &(&1.due + &2))
    cash_total = Enum.reduce(active_figures, 0, &(&1.cash + &2))
    credit_total = Enum.reduce(active_figures, 0, &(&1.credit + &2))

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
      refundable_until: Policy.refundable_until(group.policy_version, group.arrival_on),
      status: group.status,
      rooms: rooms,
      lodging_total_cents: lodging_total,
      deposit_due_cents: due_total,
      deposit_paid_cents: cash_total + credit_total,
      cash_paid_cents: cash_total,
      credit_paid_cents: credit_total,
      outstanding_deposit_cents: max(due_total - cash_total - credit_total, 0)
    }
  end
end
