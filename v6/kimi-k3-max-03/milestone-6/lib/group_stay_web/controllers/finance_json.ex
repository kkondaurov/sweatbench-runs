defmodule GroupStayWeb.FinanceJSON do
  @moduledoc false

  def render("daily_report.json", %{report: report}) do
    %{data: report}
  end

  def render("invalid_date.json", _assigns) do
    %{error: %{code: "invalid_reporting_date"}}
  end

  def render("not_available.json", _assigns) do
    %{error: %{code: "report_not_available"}}
  end
end
