defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, params) do
    case GroupStay.process_batch(params) do
      %{results: results} ->
        json(conn, %{results: results})

      {:error, :invalid_batch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
