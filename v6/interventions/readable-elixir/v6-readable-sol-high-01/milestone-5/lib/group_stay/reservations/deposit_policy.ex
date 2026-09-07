defmodule GroupStay.Reservations.DepositPolicy do
  @moduledoc """
  Selects the immutable cancellation policy for a group reservation.

  The policy is based on the original booking date. Its refundable deadline is
  based on the current arrival date, so moving a stay recomputes the deadline
  without changing the policy version.
  """

  alias GroupStay.Reservations.Group

  @flex_30_start ~D[2027-01-01]

  @doc "Returns the policy version fixed when a group is opened."
  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.before?(booked_on, @flex_30_start), do: "flex-14", else: "flex-30"
  end

  @doc "Supports pre-migration records whose version has not been persisted."
  def version(%Group{policy_version: nil} = group), do: version(group.rate_plan, group.booked_on)
  def version(%Group{policy_version: version}), do: version

  @doc "The last date on which cancellation is refundable, when applicable."
  def refundable_until(%Group{} = group) do
    case version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  @doc "Whether the group's policy permits a refund on the given date."
  def refundable?(%Group{} = group, on) do
    case refundable_until(group) do
      nil -> false
      deadline -> not Date.after?(on, deadline)
    end
  end
end
