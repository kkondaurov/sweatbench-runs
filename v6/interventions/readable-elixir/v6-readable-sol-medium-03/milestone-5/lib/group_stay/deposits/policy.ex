defmodule GroupStay.Deposits.Policy do
  @moduledoc """
  Versioned cancellation rules fixed at the time a group is opened.

  Keeping the version on the group prevents a reschedule or later policy rollout from silently
  changing the agreement made at booking time.
  """

  alias GroupStay.Deposits.Group

  @flex_30_start ~D[2027-01-01]

  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.before?(booked_on, @flex_30_start), do: "flex-14", else: "flex-30"
  end

  def refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  def refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  def refundable_until(%Group{}), do: nil

  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(occurred_on, deadline)
    end
  end
end
