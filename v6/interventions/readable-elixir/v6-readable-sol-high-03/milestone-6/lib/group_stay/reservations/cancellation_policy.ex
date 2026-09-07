defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Selects and evaluates the cancellation policy fixed when a group is booked.

  Rescheduling changes the deadline derived from arrival, but never changes the
  policy version selected from the original booking date and rate plan.
  """

  alias GroupStay.Reservations.Group

  @new_flexible_policy_starts_on ~D[2027-01-01]

  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.compare(booked_on, @new_flexible_policy_starts_on) == :lt,
      do: "flex-14",
      else: "flex-30"
  end

  def refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  def refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  def refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  def refundable?(group, cancelled_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(cancelled_on, deadline) in [:lt, :eq]
    end
  end
end
