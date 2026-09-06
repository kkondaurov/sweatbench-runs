defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, %{"date" => value}) when is_binary(value) do
    case parse_date(value) do
      {:ok, date} -> render_report(conn, Finance.daily_report(date))
      _ -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, :not_available) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end

  defp render_report(conn, report), do: json(conn, %{data: report})

  defp parse_date(value) do
    case Regex.run(~r/^(\d{4,})-(\d{2})-(\d{2})$/, value) do
      [_, year, month, day] ->
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      _ ->
        :error
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
