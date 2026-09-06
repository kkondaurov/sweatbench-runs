defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting

  @doc """
  Returns the daily finance report for `date=YYYY-MM-DD`.

  A missing or invalid date is a `422` with `invalid_reporting_date`.
  Before reporting has started, or for a date before `starts_on`, the
  report is not available and the endpoint returns `404` with
  `report_not_available`.
  """
  def show(conn, params) do
    case Map.get(params, "date") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            case FinanceReporting.daily_report(date) do
              :not_available ->
                conn
                |> put_status(:not_found)
                |> json(%{error: %{code: "report_not_available"}})

              {:ok, report} ->
                json(conn, %{data: report})
            end

          {:error, _} ->
            invalid_date(conn)
        end

      _ ->
        invalid_date(conn)
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
