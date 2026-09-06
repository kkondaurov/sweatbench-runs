defmodule GroupStayWeb.LedgerController do
  @moduledoc """
  Reads the finance totals over all groups. Credit expiry is reported as of
  the optional `on` query parameter, or the current UTC date without it.
  """

  use GroupStayWeb, :controller

  def show(conn, params) do
    json(conn, %{"data" => GroupStay.Groups.ledger_totals(as_of(params))})
  end

  defp as_of(params) do
    case params["on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _} -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end
end
