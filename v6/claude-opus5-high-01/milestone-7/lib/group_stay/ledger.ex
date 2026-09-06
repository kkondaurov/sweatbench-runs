defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals derived from the cash and hotel credit recorded against group
  reservations.

  Every cent of recorded cash sits in exactly one disposition, so held, refunded,
  retained, converted, reduced and charged-back cash add back up to everything
  the gateway ever reported. Unpaid deposit requirements are not cash and never
  appear here.
  """

  alias GroupStay.Credit
  alias GroupStay.Funding

  @doc """
  Cash by where it currently stands, plus the credit still owed to guests and the
  part of it a chargeback has left short, both as of `as_of`.
  """
  def totals(as_of) do
    cash = Funding.cash_totals()

    %{
      cash_held_cents: disposition(cash, "held"),
      cash_refunded_cents: disposition(cash, "refunded"),
      cash_retained_cents: disposition(cash, "retained"),
      cash_converted_to_credit_cents: disposition(cash, "converted"),
      cash_reduced_cents: disposition(cash, "reduced"),
      cash_charged_back_cents: disposition(cash, "charged_back"),
      credit_liability_cents: Credit.liability_cents(as_of),
      credit_shortfall_cents: Credit.shortfall_cents()
    }
  end

  defp disposition(cash, name), do: Map.get(cash, name) || 0
end
