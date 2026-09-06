defmodule GroupStay.Bookings.Policy do
  @moduledoc """
  Cancellation policy versions for group reservations.

  A flexible group's policy version is fixed by its booking date: groups booked
  before 2027-01-01 use the 14-day window, later bookings the 30-day window.
  Rescheduling never moves a group to a newer policy. Advance purchase remains
  non-refundable. The version is derived from the immutable `booked_on` date,
  so groups created before this release read with the policy their original
  booking date implies.
  """

  alias GroupStay.Bookings.Group

  @flex_cutoff ~D[2027-01-01]
  @versions %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  The policy version fixed for the group when it was opened.
  """
  def version_for(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @flex_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  def version_for(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  @doc """
  The last cancellation date that is still refundable, or nil for
  advance-purchase groups.
  """
  def refundable_until(%Group{} = group) do
    case window_days(version_for(group)) do
      nil -> nil
      days -> Date.add(group.arrival_on, -days)
    end
  end

  @doc """
  Whether a cancellation on the given date is refundable for the group.
  Cancellation on the `refundable_until` date itself is refundable.
  """
  def refundable?(%Group{} = group, cancelled_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(cancelled_on, until) != :gt
    end
  end

  defp window_days(version), do: Map.get(@versions, version)
end
