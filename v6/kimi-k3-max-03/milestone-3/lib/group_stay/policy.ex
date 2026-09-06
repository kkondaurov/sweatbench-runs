defmodule GroupStay.Policy do
  @moduledoc """
  Cancellation policy versions. A group's policy is fixed when the group is
  opened: flexible groups booked before the cutover keep the 14-day window,
  later bookings use the 30-day window, and advance-purchase groups are always
  non-refundable.
  """

  @cutover_date ~D[2027-01-01]
  @flex_14_window_days 14
  @flex_30_window_days 30

  @doc """
  Returns the `{policy_version, window_days}` for a rate plan given the
  group's booking date.
  """
  def for_plan("flexible", booked_on) do
    if Date.compare(booked_on, @cutover_date) == :lt do
      {"flex-14", @flex_14_window_days}
    else
      {"flex-30", @flex_30_window_days}
    end
  end

  def for_plan("advance_purchase", _booked_on), do: {"advance-nonrefundable", 0}

  @doc """
  The last day on which cancellation is refundable: the arrival date minus the
  policy's window. `nil` for advance-purchase policies.
  """
  def refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -@flex_14_window_days)
  def refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -@flex_30_window_days)
  def refundable_until("advance-nonrefundable", _arrival_on), do: nil

  @doc """
  Whether cancellation on `occurred_on` is refundable for a group. A
  cancellation exactly on `refundable_until` is still refundable.
  """
  def refundable?(%{refundable_until: nil}, _occurred_on), do: false

  def refundable?(%{refundable_until: refundable_until}, occurred_on) do
    Date.compare(occurred_on, refundable_until) != :gt
  end
end
