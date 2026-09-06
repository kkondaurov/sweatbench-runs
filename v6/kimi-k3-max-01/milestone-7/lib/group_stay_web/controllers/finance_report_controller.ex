defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case report_date(params) do
      {:ok, date} ->
        case Finance.report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          :not_available ->
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

  # A missing or invalid `date` query parameter is a 422.
  defp report_date(params) do
    with value when is_binary(value) <- Map.get(params, "date"),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _other -> :error
    end
  end
end
