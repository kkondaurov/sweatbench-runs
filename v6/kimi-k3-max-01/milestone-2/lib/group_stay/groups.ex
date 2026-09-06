defmodule GroupStay.Groups do
  @moduledoc """
  The groups context: group reservations, their rooms, and the deposit state
  machine (open, funded, rescheduled, cancelled).
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  # Flexible groups booked on or after this date use the 30-day cancellation
  # window; earlier bookings keep the 14-day window.
  @flex_30_cutover_on ~D[2027-01-01]

  @doc """
  Fetches a group by its partner-supplied identifier, with rooms in their
  original order. Returns `nil` when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where(group_id: ^group_id)
    |> preload(:rooms)
    |> Repo.one()
  end

  def get_group(_group_id), do: nil

  @doc """
  The number of nights in a stay.
  """
  def nights(%Group{} = group), do: Date.diff(group.departure_on, group.arrival_on)

  @doc """
  The deposit still owed by the group. Cancellation settles the requirement,
  so a cancelled group has no outstanding deposit.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  @doc """
  The cancellation policy version that applies to a group opened with the
  given rate plan and booking date. The version is fixed when the group is
  opened; rescheduling never moves a group to a newer policy.
  """
  def policy_version("advance_purchase", %Date{}), do: "advance-nonrefundable"

  def policy_version("flexible", %Date{} = booked_on) do
    if Date.compare(booked_on, @flex_30_cutover_on) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The number of calendar days before arrival that a cancellation must occur
  to be refundable under the given policy version.
  """
  def cancellation_window_days("flex-14"), do: 14
  def cancellation_window_days("flex-30"), do: 30

  @doc """
  The last date on which cancellation is refundable for the group: the
  arrival date minus its cancellation window. `nil` for advance purchase.
  """
  def refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%Group{} = group) do
    Date.shift(group.arrival_on, day: -cancellation_window_days(group.policy_version))
  end

  @doc """
  Whether cancelling the group on the given date is refundable. Cancellation
  exactly on `refundable_until` is refundable.
  """
  def refundable?(%Group{} = group, %Date{} = on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(on, until) != :gt
    end
  end

  @doc """
  Computes the lodging total and the deposit due for a stay.

  The lodging total is the sum of each room's nightly rate multiplied by the
  number of nights. Flexible rooms require 20% of their lodging as deposit;
  the percentage is calculated per room and rounded to the nearest cent with
  an exact half-cent rounding upward. Advance-purchase rooms require their
  full lodging amount.
  """
  def totals(rate_plan, rooms, nights) do
    lodging_total = Enum.sum(for room <- rooms, do: room.nightly_rate_cents * nights)

    deposit_due =
      Enum.sum(
        for room <- rooms, do: room_deposit_cents(rate_plan, room.nightly_rate_cents * nights)
      )

    %{lodging_total_cents: lodging_total, deposit_due_cents: deposit_due}
  end

  defp room_deposit_cents("flexible", lodging_cents), do: round_half_up(lodging_cents * 20, 100)
  defp room_deposit_cents("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  Rounds `numerator / denominator` to the nearest integer; an exact half
  rounds upward. Both arguments must be non-negative integers.
  """
  def round_half_up(numerator, denominator)
      when is_integer(numerator) and numerator >= 0 and is_integer(denominator) and
             denominator > 0 do
    div(2 * numerator + denominator, 2 * denominator)
  end

  @doc """
  The JSON representation of a group as returned by the read endpoint.
  """
  def group_payload(%Group{} = group) do
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
      refundable_until: refundable_until_iso8601(group),
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  @doc """
  `refundable_until` formatted for JSON responses; `nil` for advance
  purchase.
  """
  def refundable_until_iso8601(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end
end
