defmodule GroupStay.Pricing do
  @moduledoc """
  Deposit and lodging arithmetic. All amounts are integer cents.
  """

  @flexible_deposit_percent 20

  @doc "Nights between two calendar dates."
  def nights(arrival_on, departure_on), do: Date.diff(departure_on, arrival_on)

  @doc "Lodging owed for one room over the stay."
  def lodging_cents(nightly_rate_cents, nights), do: nightly_rate_cents * nights

  @doc """
  Deposit required for a single room's lodging amount under a rate plan.

  Flexible rooms require 20%; advance-purchase rooms require the full amount.
  """
  def room_deposit_cents("flexible", lodging_cents),
    do: percent_of(lodging_cents, @flexible_deposit_percent)

  def room_deposit_cents("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  A percentage of an amount, rounded to the nearest cent with an exact half-cent
  rounding upward.
  """
  def percent_of(amount_cents, percent) when amount_cents >= 0,
    do: div(amount_cents * percent + 50, 100)
end
