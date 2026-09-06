defmodule GroupStay.Money do
  @moduledoc """
  Arithmetic helpers for integer-cent monetary amounts.

  Percentage results are rounded to the nearest cent; an exact half-cent
  rounds upward.
  """

  @doc """
  Returns `percent` of `amount_cents`, rounded to the nearest cent with
  half-cent ties rounding upward.
  """
  def percent(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 and is_integer(percent) and
             percent >= 0 do
    div(amount_cents * percent + 50, 100)
  end
end
