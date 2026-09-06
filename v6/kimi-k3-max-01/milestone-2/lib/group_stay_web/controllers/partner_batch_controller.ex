defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  alias GroupStay.Batches

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = Batches.apply_operations(operations)
    json(conn, %{results: results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
