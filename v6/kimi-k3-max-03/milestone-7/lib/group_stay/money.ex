defmodule GroupStay.Money do
  @moduledoc """
  Integer-cent arithmetic. Percentages round to the nearest cent and an exact
  half-cent rounds upward.
  """

  @doc """
  Returns `amount * percent / 100`, rounded to the nearest cent with
  half cents rounded up. `amount` and `percent` must be non-negative.
  """
  def percent_of(amount, percent) when amount >= 0 and percent >= 0 do
    div(amount * percent + 50, 100)
  end
end
