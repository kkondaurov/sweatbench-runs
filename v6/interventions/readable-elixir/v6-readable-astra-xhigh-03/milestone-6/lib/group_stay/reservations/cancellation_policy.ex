defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  The cancellation terms agreed at booking, independent of later reschedules.

  Policy versions are persisted on groups. Their deadlines follow the current
  arrival date, and the last refundable date is inclusive.
  """

  def version(:advance_purchase, _booked_on), do: "advance-nonrefundable"

  def version(:flexible, booked_on) do
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
