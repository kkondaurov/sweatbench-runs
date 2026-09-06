defmodule GroupStay.Money do
  @moduledoc """
  Shared cent arithmetic: the standard rounding rule and the hotel-credit
  bonus value.
  """

  @credit_bonus_percent 10

  @doc """
  Rounds a percentage of an amount to the nearest cent; an exact half-cent
  rounds upward.
  """
  def rounded_percentage(amount_cents, percent) do
    dividend = amount_cents * percent
    quotient = div(dividend, 100)
    remainder = rem(dividend, 100)

    if remainder * 2 >= 100, do: quotient + 1, else: quotient
  end

  @doc """
  The credit value of converted cash: the cash plus its 10% bonus, rounded
  with the standard rule.
  """
  def credit_value(cash_cents) do
    cash_cents + rounded_percentage(cash_cents, @credit_bonus_percent)
  end
end
