defmodule GroupStayWeb.LedgerJSON do
  @moduledoc """
  Renders finance totals for cash held, refunded, retained, converted to
  hotel credit, and the outstanding credit liability.
  """

  def show(%{totals: totals}) do
    %{data: totals}
  end
end
