defmodule GroupStayWeb.LedgerJSON do
  @moduledoc false

  def render("show.json", %{totals: totals}) do
    %{
      data: %{
        cash_held_cents: totals.cash_held_cents,
        cash_refunded_cents: totals.cash_refunded_cents,
        cash_retained_cents: totals.cash_retained_cents,
        cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents,
        cash_reduced_cents: totals.cash_reduced_cents,
        cash_charged_back_cents: totals.cash_charged_back_cents,
        credit_liability_cents: totals.credit_liability_cents,
        credit_shortfall_cents: totals.credit_shortfall_cents
      }
    }
  end
end
