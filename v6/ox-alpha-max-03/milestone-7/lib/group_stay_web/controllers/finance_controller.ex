defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  action_fallback GroupStayWeb.FallbackController

  def show(conn, params) do
    case reporting_date(params) do
      {:ok, date} ->
        case Deposits.daily_report(date) do
          {:ok, report} -> render(conn, :show, report: report)
          {:error, reason} -> {:error, reason}
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  # A missing or unusable `date` query parameter is an invalid reporting date.
  defp reporting_date(params) do
    case params["date"] do
      nil -> :error
      value when is_binary(value) -> parse_date(value)
      _other -> :error
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end
end
