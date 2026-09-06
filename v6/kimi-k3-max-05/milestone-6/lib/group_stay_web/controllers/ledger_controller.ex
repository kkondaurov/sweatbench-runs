defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, params) do
    json(conn, %{"data" => Ledger.totals(as_of(params))})
  end

  # Reports expiry as of the `on` query parameter; the current UTC date when
  # it is absent or unusable.
  defp as_of(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp as_of(_params), do: Date.utc_today()
end
