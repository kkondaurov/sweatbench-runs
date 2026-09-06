defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Partner

  def create(conn, params) do
    case Partner.process_batch(params) do
      {:ok, results} ->
        render(conn, :create, results: results)

      {:error, :invalid_batch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_batch"}})
    end
  end
end
