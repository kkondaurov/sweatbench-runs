defmodule GroupStay.Money do
  @moduledoc false

  def percent(amount_cents, percent)
      when is_integer(amount_cents) and is_integer(percent) and amount_cents >= 0 and percent >= 0 do
    div(amount_cents * percent + 50, 100)
  end
end
