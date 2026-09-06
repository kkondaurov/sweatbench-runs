defmodule GroupStay.CancellationPolicy do
  @cutover_date ~D[2027-01-01]

  def version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def version("flexible", booked_on) do
    if Date.compare(booked_on, @cutover_date) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  def refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  def refundable_until("advance-nonrefundable", _arrival_on), do: nil

  def refundable?(policy_version, arrival_on, occurred_on) do
    case refundable_until(policy_version, arrival_on) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end
end
