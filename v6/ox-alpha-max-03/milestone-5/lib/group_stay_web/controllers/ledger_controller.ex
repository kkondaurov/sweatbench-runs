defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, _params) do
    render(conn, :show, totals: Deposits.ledger_totals(on_date(conn)))
  end

  # Credit expiry is reported as of the `on` query parameter when it carries
  # a usable date; otherwise the current UTC date is used.
  defp on_date(conn) do
    case conn.query_params["on"] do
      nil -> Date.utc_today()
      value -> parse_date(value) || Date.utc_today()
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil
end
