defmodule GroupStay.Groups.Policy do
  @moduledoc """
  The cancellation policy that applies to a group.

  A group's policy version is fixed when the group is opened: flexible groups
  booked before 2027-01-01 keep the 14-day window, flexible groups booked on
  or after that date use the 30-day window, and advance-purchase groups are
  never refundable. Rescheduling never moves a group to a newer policy.
  """

  alias GroupStay.Groups.Group

  @policy_cutoff ~D[2027-01-01]
  @flex_14_window 14
  @flex_30_window 30

  @doc """
  Returns the policy version fixed for the group: `"flex-14"`, `"flex-30"`,
  or `"advance-nonrefundable"`.
  """
  def version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def version(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  Returns the last date on which the group can be cancelled refundably, or
  nil for advance-purchase groups.
  """
  def refundable_until(%Group{rate_plan: "advance_purchase"}), do: nil

  def refundable_until(%Group{} = group) do
    Date.add(group.arrival_on, -window(group))
  end

  @doc """
  Returns whether cancelling the group on the given date is refundable.
  Cancellation exactly on `refundable_until/1` is refundable.
  """
  def refundable?(%Group{rate_plan: "flexible"} = group, occurred_on) do
    Date.diff(group.arrival_on, occurred_on) >= window(group)
  end

  def refundable?(_group, _occurred_on), do: false

  defp window(%Group{} = group) do
    case version(group) do
      "flex-14" -> @flex_14_window
      "flex-30" -> @flex_30_window
    end
  end
end
