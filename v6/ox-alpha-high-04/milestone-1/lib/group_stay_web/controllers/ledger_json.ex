defmodule GroupStayWeb.LedgerJSON do
  @moduledoc """
  Renders finance totals.
  """

  def show(%{totals: totals}) do
    %{
      "cash_held_cents" => totals.cash_held_cents,
      "cash_refunded_cents" => totals.cash_refunded_cents,
      "cash_retained_cents" => totals.cash_retained_cents
    }
  end
end
