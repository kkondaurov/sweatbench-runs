defmodule GroupStayWeb.LedgerJSON do
  @moduledoc false

  def render("show.json", %{totals: totals}) do
    %{
      data: %{
        cash_held_cents: totals.cash_held_cents,
        cash_refunded_cents: totals.cash_refunded_cents,
        cash_retained_cents: totals.cash_retained_cents,
        cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents,
        credit_liability_cents: totals.credit_liability_cents
      }
    }
  end
end
