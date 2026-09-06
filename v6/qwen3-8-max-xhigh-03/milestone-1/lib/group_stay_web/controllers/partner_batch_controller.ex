defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    results = GroupStay.Operations.apply_batch(operations)
    json(conn, %{results: results})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
