defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    json(conn, %{"data" => Finance.totals(on_date(params))})
  end

  defp on_date(params) do
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
