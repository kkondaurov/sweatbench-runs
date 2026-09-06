defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def index(conn, params) do
    case GroupStayWeb.OnDate.fetch(params) do
      {:ok, on_date} ->
        json(conn, %{data: Finance.totals(on_date)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_parameter"}})
    end
  end
end
