defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Cancellation terms fixed at booking time. Moving a stay changes its refundable
  deadline, but never the policy version agreed when the group was opened.
  Deadlines are inclusive calendar dates.
  """

  def version(:advance_purchase, _booked_on), do: "advance-nonrefundable"

  def version(:flexible, booked_on) do
    if Date.before?(booked_on, ~D[2027-01-01]), do: "flex-14", else: "flex-30"
  end

  def refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  def refundable_until(%{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end
end
