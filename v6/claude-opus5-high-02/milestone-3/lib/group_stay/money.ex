defmodule GroupStay.Money do
  @moduledoc """
  Integer-cent arithmetic shared by the deposit and credit rules.
  """

  @doc """
  A percentage of an amount, rounded to the nearest cent with an exact half-cent rounding upward.
  """
  def percent_of(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 and is_integer(percent),
      do: div(amount_cents * percent + 50, 100)
end
