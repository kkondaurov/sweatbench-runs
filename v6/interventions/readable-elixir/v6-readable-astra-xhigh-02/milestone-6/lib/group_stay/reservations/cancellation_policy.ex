defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Cancellation terms chosen at booking time and kept for the life of a group.
  Moving a stay changes its refund deadline, but never its policy version.
  The deadline itself is inclusive.
  """

  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%{policy_version: "flex-14", arrival_on: arrival}),
    do: Date.add(arrival, -14)

  def refundable_until(%{policy_version: "flex-30", arrival_on: arrival}),
    do: Date.add(arrival, -30)

  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end
end
