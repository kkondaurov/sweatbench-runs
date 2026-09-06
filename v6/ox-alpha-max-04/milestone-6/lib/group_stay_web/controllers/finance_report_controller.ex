defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  @doc """
  Renders the daily finance report for the `date` query parameter: how held
  cash moved per property and how hotel-credit liability moved company-wide.
  A missing or invalid date is rejected as `invalid_reporting_date`; before
  reporting has started, or for a date before `starts_on`, no report is
  available. Reading a report never changes state.
  """
  def show(conn, params) do
    case reporting_date(params["date"]) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          {:error, :report_not_available} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp reporting_date(_value), do: :error
end
