defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    json(conn, %{data: Groups.ledger_totals(as_of(params))})
  end

  defp as_of(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end
end
