defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, _params) do
    case GroupStay.PartnerBatches.submit(conn.body_params) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, :invalid_batch} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
