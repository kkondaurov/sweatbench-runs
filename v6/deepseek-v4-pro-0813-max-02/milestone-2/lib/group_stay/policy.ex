defmodule GroupStay.Policy do
  @moduledoc """
  Cancellation policy versions.

  Flexible groups booked before 2027-01-01 keep the 14-day cancellation
  window. Flexible groups booked on or after that date use a 30-day window.
  Advance-purchase reservations are always non-refundable. A group's policy
  version is fixed when the group is opened and never changes afterwards.
  """

  @cutover ~D[2027-01-01]

  @windows %{
    "flex-14" => 14,
    "flex-30" => 30,
    "advance-nonrefundable" => :none
  }

  @doc """
  The policy version implied by a rate plan and booking date.
  """
  @spec policy_version(String.t(), Date.t()) :: String.t()
  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The policy version recorded for a group, falling back to the version implied
  by its rate plan and booking date for groups created before policy versions
  were stored.
  """
  @spec for_group(map()) :: String.t()
  def for_group(%{rate_plan: rate_plan, booked_on: booked_on, policy_version: nil}),
    do: policy_version(rate_plan, booked_on)

  def for_group(%{policy_version: policy_version}), do: policy_version

  @doc """
  Returns the last day a cancellation is still refundable, or `nil` for
  non-refundable policies. Cancellation on this date is refundable.
  """
  @spec refundable_until(String.t(), Date.t()) :: Date.t() | nil
  def refundable_until(policy_version, arrival_on) do
    case @windows do
      %{^policy_version => days} when is_integer(days) -> Date.add(arrival_on, -days)
      _ -> nil
    end
  end

  @doc """
  Whether a cancellation occurring on `occurred_on` is refundable.
  """
  @spec refundable?(String.t(), Date.t(), Date.t()) :: boolean()
  def refundable?(policy_version, arrival_on, occurred_on) do
    case @windows do
      %{^policy_version => days} when is_integer(days) ->
        Date.diff(arrival_on, occurred_on) >= days

      _ ->
        false
    end
  end
end
