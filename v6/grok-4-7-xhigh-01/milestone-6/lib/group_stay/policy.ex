defmodule GroupStay.Policy do
  @moduledoc false

  @cutoff ~D[2027-01-01]
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance "advance-nonrefundable"

  def for_group(%{rate_plan: "advance_purchase"}) do
    %{version: @advance, refundable_until: nil}
  end

  def for_group(%{rate_plan: "flexible", booked_on: booked_on, arrival_on: arrival_on}) do
    version = if Date.compare(booked_on, @cutoff) == :lt, do: @flex_14, else: @flex_30

    %{
      version: version,
      refundable_until: Date.add(arrival_on, -window_days(version))
    }
  end

  def refundable?(%{rate_plan: "advance_purchase"}, _occurred_on), do: false

  def refundable?(group, occurred_on) do
    until = for_group(group).refundable_until
    Date.compare(occurred_on, until) != :gt
  end

  defp window_days(@flex_14), do: 14
  defp window_days(@flex_30), do: 30
end
