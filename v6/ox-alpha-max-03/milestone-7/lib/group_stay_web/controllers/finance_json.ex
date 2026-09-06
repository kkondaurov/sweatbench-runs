defmodule GroupStayWeb.FinanceJSON do
  @moduledoc """
  Renders the daily finance report: held cash by property with its signed
  movements, the company-wide hotel-credit liability, and the late
  adjustments a period close moved onto the day. Reports a close published
  are served verbatim from their stored snapshot.
  """

  def show(%{report: report}) do
    %{data: report}
  end
end
