defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reporting

  @doc """
  One day of the finance report. A missing or invalid `date` is the
  reporting date's own rejection; before reporting started, or before its
  `starts_on`, the report does not exist yet.
  """
  def show(conn, params) do
    case parse_date(params["date"]) do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, Jason.encode!(%{error: %{code: "invalid_reporting_date"}}))

      date ->
        case Reporting.daily_report(date) do
          {:ok, report} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{data: report}))

          {:error, :not_available} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, Jason.encode!(%{error: %{code: "report_not_available"}}))
        end
    end
  end

  defp parse_date(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_other), do: nil
end
