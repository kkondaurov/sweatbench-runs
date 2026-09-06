defmodule GroupStayWeb.FinanceJSON do
  @moduledoc "Renders one day of finance movements."

  def daily_report(%{report: report}), do: %{data: report}
end
