defmodule GroupStay.Deposits do
  @moduledoc false

  @flexible_percent 20

  def quote(rooms, nights, rate_plan) when is_integer(nights) and nights >= 1 do
    lodgings = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(lodgings)

    deposit_due =
      case rate_plan do
        "flexible" ->
          lodgings |> Enum.map(&rounded_percent(&1, @flexible_percent)) |> Enum.sum()

        "advance_purchase" ->
          lodging_total
      end

    %{lodging_total_cents: lodging_total, deposit_due_cents: deposit_due}
  end

  def rounded_percent(amount_cents, percent)
      when is_integer(amount_cents) and amount_cents >= 0 and is_integer(percent) and percent >= 0 do
    div(amount_cents * percent + 50, 100)
  end
end
