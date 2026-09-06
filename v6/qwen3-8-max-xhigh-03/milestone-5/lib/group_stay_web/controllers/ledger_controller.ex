defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Repo
  alias GroupStay.Groups
  alias GroupStay.Groups.Backfill

  def index(conn, params) do
    case GroupStayWeb.AsOf.parse(params) do
      {:ok, as_of} ->
        {:ok, ledger} =
          Repo.transaction(fn ->
            Backfill.backfill_all()
            Groups.ledger(as_of)
          end)

        json(conn, %{data: ledger})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
