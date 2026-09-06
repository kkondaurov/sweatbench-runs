defmodule GroupStay.Groups do
  @moduledoc """
  The group reservation domain: stay math, deposit requirements, cancellation
  policy versions, room accounting, and reads.

  Cash and hotel credit fund the active rooms' deposits, and the group's
  lodging, due, paid, and outstanding totals describe those active rooms
  only. Every room in the response carries its own status, deposit
  requirement, and the cash and credit paid on it.
  """

  alias GroupStay.Accounting
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  import Ecto.Query

  @flexible_deposit_percent 20
  @flexible_policy_cutoff ~D[2027-01-01]

  @cancellation_windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  Loads a group by its partner identifier together with its rooms (and their
  allocations) in the original order supplied at open time.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> preload_rooms(group)
    end
  end

  @doc "Preloads a group's rooms (with their allocations) in original order."
  def preload_rooms(%Group{} = group) do
    Repo.preload(group, rooms: {ordered_rooms(), :allocations})
  end

  defp ordered_rooms do
    from r in Room, order_by: r.position, preload: [:allocations]
  end

  @doc """
  The policy version fixed when a flexible group is opened: flexible groups
  booked before 2027-01-01 keep the 14-day cancellation window, groups booked
  on or after 2027-01-01 use a 30-day window, and advance-purchase groups are
  always non-refundable.
  """
  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flexible_policy_cutoff) == :lt do
      "flex-14"
    else
      "flex-30"
    end
  end

  @doc "Number of nights between arrival and departure."
  def nights(%Group{} = group) do
    Date.diff(group.departure_on, group.arrival_on)
  end

  @doc "A room's lodging amount: nights multiplied by its nightly rate."
  def room_lodging_cents(%Group{} = group, %Room{} = room) do
    nights(group) * room.nightly_rate_cents
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

  @doc "The group's active rooms in their original order."
  def active_rooms(%Group{} = group) do
    Accounting.active_rooms(group)
  end

  @doc "The group lodging total: the sum of the active rooms' lodging amounts."
  def lodging_total_cents(%Group{} = group) do
    group
    |> active_rooms()
    |> Enum.sum_by(&room_lodging_cents(group, &1))
  end

  @doc """
  The group deposit requirement: each active room's deposit is calculated
  and rounded separately, then the room deposits are summed.
  """
  def deposit_due_cents(%Group{} = group) do
    group
    |> active_rooms()
    |> Enum.sum_by(&room_deposit_cents(group, &1))
  end

  @doc "Cash currently held on the group's active rooms."
  def cash_paid_cents(%Group{} = group) do
    held_on_active_rooms(group, "cash")
  end

  @doc "Hotel credit currently held on the group's active rooms."
  def credit_paid_cents(%Group{} = group) do
    held_on_active_rooms(group, "credit")
  end

  @doc "Cash and hotel credit held on the group's active rooms."
  def deposit_paid_cents(%Group{} = group) do
    cash_paid_cents(group) + credit_paid_cents(group)
  end

  @doc """
  The deposit still owed. An unpaid deposit is no longer due once its room is
  cancelled; a fully cancelled group owes nothing.
  """
  def outstanding_deposit_cents(%Group{} = group) do
    deposit_due_cents(group) - deposit_paid_cents(group)
  end

  defp held_on_active_rooms(%Group{} = group, kind) do
    group
    |> active_rooms()
    |> Enum.flat_map(& &1.allocations)
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sum_by(& &1.remaining_cents)
  end

  @doc """
  The last date on which cancelling the group is refundable: the arrival date
  minus the group's cancellation window. It is `nil` for advance purchase.
  """
  def refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%Group{} = group) do
    Date.add(group.arrival_on, -@cancellation_windows[group.policy_version])
  end

  @doc "Whether a cancellation on `occurred_on` is refundable."
  def refundable?(%Group{policy_version: "advance-nonrefundable"}, _occurred_on), do: false

  def refundable?(%Group{} = group, occurred_on) do
    Date.compare(occurred_on, refundable_until(group)) != :gt
  end

  @doc "Renders a group (with preloaded rooms and allocations) as the partner API payload."
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
      "policy_version" => group.policy_version,
      "refundable_until" => render_date(refundable_until(group)),
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "status" => room.status,
            "deposit_due_cents" => room_deposit_cents(group, room),
            "cash_paid_cents" => Accounting.room_paid_cents(room, "cash"),
            "credit_paid_cents" => Accounting.room_paid_cents(room, "credit")
          }
        end),
      "lodging_total_cents" => lodging_total_cents(group),
      "deposit_due_cents" => deposit_due_cents(group),
      "deposit_paid_cents" => deposit_paid_cents(group),
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => credit_paid_cents(group),
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp render_date(nil), do: nil
  defp render_date(%Date{} = date), do: Date.to_iso8601(date)

  # `amount_cents * percent / 100` rounded to the nearest cent; an exact
  # half-cent rounds upward.
  defp round_percent(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end
end
