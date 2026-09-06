defmodule GroupStay.Groups.Policy do
  @moduledoc """
  Cancellation policy versions for group reservations.

  Flexible groups booked before `2027-01-01` use `flex-14`, the 14-day
  cancellation window; flexible groups booked on or after that date use
  `flex-30`, the 30-day window. Advance-purchase groups are
  `advance-nonrefundable`. A group's version is fixed when the group is
  opened, so rescheduling never moves it to a newer policy.

  Cancellation on the group's `refundable_until` date - the arrival date
  minus the window - is still refundable.
  """

  @policy_boundary ~D[2027-01-01]
  @windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  The policy version implied by a rate plan and the group's booking date.
  """
  @spec for_rate_plan(String.t(), Date.t()) :: String.t()
  def for_rate_plan("flexible", booked_on) do
    if Date.compare(booked_on, @policy_boundary) == :lt, do: "flex-14", else: "flex-30"
  end

  def for_rate_plan("advance_purchase", _booked_on), do: "advance-nonrefundable"

  @doc """
  The cancellation window in calendar days for a flexible policy version.
  """
  @spec window(String.t()) :: pos_integer()
  def window(policy_version), do: Map.fetch!(@windows, policy_version)

  @doc """
  Whether a cancellation on `occurred_on` is refundable under the group's
  fixed policy version: flexible groups are refundable when at least a full
  window of days remains before arrival, advance-purchase groups never are.
  """
  @spec refundable?(String.t(), Date.t(), Date.t()) :: boolean()
  def refundable?(policy_version, arrival_on, occurred_on) do
    case @windows[policy_version] do
      nil -> false
      days -> Date.diff(arrival_on, occurred_on) >= days
    end
  end

  @doc """
  The last cancellation date that is refundable under the policy version, or
  `nil` when the policy never refunds.
  """
  @spec refundable_until(String.t(), Date.t()) :: Date.t() | nil
  def refundable_until(policy_version, arrival_on) do
    case @windows[policy_version] do
      nil -> nil
      days -> Date.add(arrival_on, -days)
    end
  end
end
