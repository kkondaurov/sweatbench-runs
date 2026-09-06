defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay

  def show(conn, params) do
    as_of = parsed_on(params["on"]) || Date.utc_today()
    totals = GroupStay.finance_totals(as_of: as_of)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{data: GroupStayWeb.LedgerJSON.show(%{totals: totals})}))
  end

  defp parsed_on(nil), do: nil

  defp parsed_on(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parsed_on(_other), do: nil
end
