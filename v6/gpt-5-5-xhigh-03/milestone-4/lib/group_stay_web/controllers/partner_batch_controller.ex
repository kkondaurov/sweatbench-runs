defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def create(conn, params) do
    case Reservations.process_batch(params) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, :invalid_batch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
