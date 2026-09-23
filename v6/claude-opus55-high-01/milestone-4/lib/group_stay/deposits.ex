defmodule GroupStay.Deposits do
  @moduledoc """
  Deposit pricing for group rooms.
  """

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20

  def rate_plans, do: @rate_plans

  @doc "Lodging amount for one room over the given number of nights."
  def room_lodging_cents(nights, nightly_rate_cents), do: nights * nightly_rate_cents

  @doc "Deposit required for one room's lodging amount under a rate plan."
  def room_deposit_cents("flexible", lodging_cents),
    do: percentage_cents(lodging_cents, @flexible_deposit_percent)

  def room_deposit_cents("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  `percent` of a non-negative cent amount, rounded to the nearest cent with an exact half-cent
  rounding upward.
  """
  def percentage_cents(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 and is_integer(percent) do
    div(amount_cents * percent * 2 + 100, 200)
  end
end
