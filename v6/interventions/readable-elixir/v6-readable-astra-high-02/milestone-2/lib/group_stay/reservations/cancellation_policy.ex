defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Cancellation terms selected once at booking. Moving a stay changes its deadline,
  but never its policy version. Deadlines are inclusive calendar dates.
  """

  def version(:advance_purchase, _booked_on), do: "advance-nonrefundable"

  def version(:flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%{policy_version: version, arrival_on: arrival}) do
    days =
      case version do
        "flex-14" -> 14
        "flex-30" -> 30
      end

    Date.add(arrival, -days)
  end

  def refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end
end
