defmodule GroupStay.Reservations.Policy do
  @moduledoc "Cancellation terms are selected at booking and stay fixed through rescheduling."

  def version("advance_purchase", _), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  def refundable_until(%{policy_version: version, arrival_on: arrival}) do
    Date.add(arrival, if(version == "flex-14", do: -14, else: -30))
  end

  def refundable?(group, on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(on, cutoff) != :gt
    end
  end
end
