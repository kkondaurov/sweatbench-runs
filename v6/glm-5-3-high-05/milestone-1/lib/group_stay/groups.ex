defmodule GroupStay.Groups do
  @moduledoc """
  The group reservation domain: stay math, deposit requirements, and reads.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Repo

  import Ecto.Query

  @flexible_deposit_percent 20

  @doc """
  Loads a group by its partner identifier together with its rooms in the
  original order supplied at open time.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, rooms: ordered_rooms())
    end
  end

  defp ordered_rooms do
    from r in Room, order_by: r.position
  end

  @doc "Number of nights between arrival and departure."
  def nights(%Group{} = group) do
    Date.diff(group.departure_on, group.arrival_on)
  end

  @doc "A room's lodging amount: nights multiplied by its nightly rate."
  def room_lodging_cents(%Group{} = group, %Room{} = room) do
    nights(group) * room.nightly_rate_cents
  end

  @doc "The group lodging total: the sum of the room lodging amounts."
  def lodging_total_cents(%Group{} = group) do
    Enum.sum_by(group.rooms, &room_lodging_cents(group, &1))
  end

  @doc """
  A room's deposit requirement. Flexible rooms require 20% of their lodging
  amount, rounded to the nearest cent (an exact half-cent rounds upward).
  Advance-purchase rooms require their full lodging amount.
  """
  def room_deposit_cents(%Group{rate_plan: "advance_purchase"} = group, %Room{} = room) do
    room_lodging_cents(group, room)
  end

  def room_deposit_cents(%Group{rate_plan: "flexible"} = group, %Room{} = room) do
    round_percent(room_lodging_cents(group, room), @flexible_deposit_percent)
  end

  @doc """
  The group deposit requirement: each room's deposit is calculated and rounded
  separately, then the room deposits are summed.
  """
  def deposit_due_cents(%Group{} = group) do
    Enum.sum_by(group.rooms, &room_deposit_cents(group, &1))
  end

  @doc "Cash paid to the group's deposit so far."
  def deposit_paid_cents(%Group{} = group) do
    Ledger.paid_cents(group.id)
  end

  @doc """
  The deposit still owed. An unpaid deposit is no longer due once the group is
  cancelled.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"} = _group) do
    0
  end

  def outstanding_deposit_cents(%Group{} = group) do
    deposit_due_cents(group) - deposit_paid_cents(group)
  end

  @doc "Renders a group (with preloaded rooms) as the partner API payload."
  def render(%Group{} = group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => lodging_total_cents(group),
      "deposit_due_cents" => deposit_due_cents(group),
      "deposit_paid_cents" => deposit_paid_cents(group),
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  # `amount_cents * percent / 100` rounded to the nearest cent; an exact
  # half-cent rounds upward.
  defp round_percent(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end
end
