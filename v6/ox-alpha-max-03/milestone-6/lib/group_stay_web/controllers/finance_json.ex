defmodule GroupStayWeb.FinanceJSON do
  @moduledoc """
  Renders the daily finance report: held cash by property with its signed
  movements and the company-wide hotel-credit liability.
  """

  def show(%{report: report}) do
    %{data: report}
  end
end
