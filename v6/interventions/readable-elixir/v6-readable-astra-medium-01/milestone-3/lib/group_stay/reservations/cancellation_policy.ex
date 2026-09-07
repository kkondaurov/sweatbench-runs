defmodule GroupStay.Reservations.CancellationPolicy do
  @moduledoc """
  Booking-date policy selection is persisted at opening. Only the refund cutoff
  moves when a stay is rescheduled; the selected cancellation window never does.
  """

  def version("advance_purchase", _), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil
  def refundable_until(%{policy_version: "flex-14", arrival_on: date}), do: Date.add(date, -14)
  def refundable_until(%{policy_version: "flex-30", arrival_on: date}), do: Date.add(date, -30)

  def refundable?(group, on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(on, cutoff) != :gt
    end
  end
end
