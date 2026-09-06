defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Reporting

  def daily(conn, params) do
    with {:ok, date} <- parse_date(params),
         {:ok, state} <- reporting_state() do
      if Date.compare(date, state.starts_on) == :lt do
        not_available(conn)
      else
        render(conn, :daily_report, report: Reporting.daily_report(state, date))
      end
    else
      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:invalid_date)

      {:error, :not_started} ->
        not_available(conn)
    end
  end

  defp not_available(conn) do
    conn
    |> put_status(:not_found)
    |> render(:not_available)
  end

  # The `date` query parameter must be a usable ISO 8601 date.
  defp parse_date(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_date}
    end
  end

  defp parse_date(_params), do: {:error, :invalid_date}

  defp reporting_state do
    case Reporting.state() do
      nil -> {:error, :not_started}
      state -> {:ok, state}
    end
  end
end
