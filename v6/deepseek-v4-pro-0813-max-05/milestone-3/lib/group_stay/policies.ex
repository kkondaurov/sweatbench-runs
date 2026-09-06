defmodule GroupStay.Policies do
  @moduledoc """
  Cancellation policy for a group reservation.

  A group's policy is fixed when the group is opened and is derived from
  the booking date and rate plan, both of which never change after opening.
  Flexible groups booked before 2027-01-01 keep the 14-day cancellation
  window; flexible groups booked on or after 2027-01-01 use 30 days.
  Advance-purchase groups are never refundable.
  """

  @cutover ~D[2027-01-01]
  @flex14_window 14
  @flex30_window 30

  @doc "The group's policy version: `flex-14`, `flex-30`, or `advance-nonrefundable`."
  def policy_version(%{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The number of cancellation days for the group, or `nil` when the group
  can never be refunded.
  """
  def cancellation_window(group) do
    case policy_version(group) do
      "flex-14" -> @flex14_window
      "flex-30" -> @flex30_window
      "advance-nonrefundable" -> nil
    end
  end

  @doc """
  The last date on which cancelling the group is refundable, or `nil` for
  advance purchase. Cancelling on the date itself is refundable.
  """
  def refundable_until(group), do: refundable_until_for(group, group.arrival_on)

  @doc "The refundable-until date for a given arrival date."
  def refundable_until_for(group, arrival_on) do
    case cancellation_window(group) do
      nil -> nil
      window -> Date.add(arrival_on, -window)
    end
  end

  @doc """
  Whether cancelling `group` on `occurred_on` refunds cash already paid.
  """
  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end
end
