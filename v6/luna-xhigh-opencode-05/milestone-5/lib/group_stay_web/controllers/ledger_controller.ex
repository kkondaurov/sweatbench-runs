defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case report_date(params) do
      {:ok, on_date} -> json(conn, %{"data" => Groups.ledger(on_date)})
      :error -> invalid_date(conn)
    end
  end

  defp report_date(%{"on" => on}) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp report_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_date"}})
  end
end
