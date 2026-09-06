defmodule GroupStayWeb.LedgerJSON do
  @moduledoc "Renders the finance totals GroupStay keeps."

  def show(%{totals: totals}), do: %{data: totals}
end
