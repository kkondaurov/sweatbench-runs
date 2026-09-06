defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def create(conn, params) do
    case Operations.run_batch(params["operations"]) do
      {:ok, results} ->
        json(conn, %{"results" => results})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_batch"}})
    end
  end
end
