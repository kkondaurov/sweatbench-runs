defmodule GroupStay.Policy do
  @moduledoc """
  Cancellation policy versions.

  A group's policy version is fixed when the group is opened from its rate
  plan and booking date: flexible groups booked before `2027-01-01` use the
  14-day window (`flex-14`), later flexible groups the 30-day window
  (`flex-30`), and advance-purchase groups are always non-refundable.
  Rescheduling changes arrival dates but never the fixed policy version.
  """

  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"

  @versions [@flex_14, @flex_30, @advance_nonrefundable]

  @new_flex_window_start ~D[2027-01-01]

  @type version :: String.t()

  def versions, do: @versions

  @doc """
  The policy version implied by a rate plan and booking date.
  """
  def version_for("flexible", %Date{} = booked_on) do
    if Date.compare(booked_on, @new_flex_window_start) == :lt,
      do: @flex_14,
      else: @flex_30
  end

  def version_for("advance_purchase", %Date{}), do: @advance_nonrefundable

  @doc """
  The cancellation window in calendar days before arrival, or `nil` when the
  policy is non-refundable regardless of notice.
  """
  def window_days(@flex_14), do: 14
  def window_days(@flex_30), do: 30
  def window_days(@advance_nonrefundable), do: nil

  @doc """
  The last arrival-relative date on which cancellation is refundable:
  arrival minus the policy's window. Cancellation on that date itself is
  refundable. `nil` for non-refundable policies.
  """
  def refundable_until(version, arrival_on)

  def refundable_until(version, %Date{} = arrival_on) when version in [@flex_14, @flex_30] do
    Date.add(arrival_on, -window_days(version))
  end

  def refundable_until(@advance_nonrefundable, %Date{}), do: nil

  @doc """
  Whether a cancellation on `occurred_on` is refundable under the policy.
  """
  def refundable?(version, arrival_on, occurred_on) do
    case refundable_until(version, arrival_on) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end
end
