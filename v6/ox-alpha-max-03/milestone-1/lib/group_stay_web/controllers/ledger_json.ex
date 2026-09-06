defmodule GroupStayWeb.LedgerJSON do
  @moduledoc """
  Renders finance totals for cash held, refunded, and retained.
  """

  def show(%{totals: totals}) do
    %{data: totals}
  end
end
