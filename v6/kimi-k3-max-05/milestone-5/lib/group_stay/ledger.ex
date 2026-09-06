defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals across all groups. Cash held on active reservations moves to
  refunded, retained, or converted-to-credit when rooms are cancelled; provider
  corrections reduce held cash, and chargebacks reclassify a payment's cash as
  charged back. Unpaid deposits never appear.

  Recorded cash equals the sum of held, refunded, retained, converted,
  reduced, and charged-back cash.
  """

  alias GroupStay.Credits
  alias GroupStay.Funding

  @doc """
  Returns the finance totals as of the given date: cash by disposition, and
  the outstanding hotel-credit liability and shortfall.
  """
  def totals(on_date) do
    cash = Funding.totals_by_status()

    %{
      "cash_held_cents" => Map.get(cash, "held", 0),
      "cash_refunded_cents" => Map.get(cash, "refunded", 0),
      "cash_retained_cents" => Map.get(cash, "retained", 0),
      "cash_converted_to_credit_cents" => Map.get(cash, "converted", 0),
      "cash_reduced_cents" => Map.get(cash, "reduced", 0),
      "cash_charged_back_cents" => Map.get(cash, "charged_back", 0),
      "credit_liability_cents" => Credits.liability_cents(on_date),
      "credit_shortfall_cents" => Credits.shortfall_cents()
    }
  end
end
