defmodule GroupStayWeb.PartnerBatchController do
  use GroupStayWeb, :controller

  def create(conn, %{"operations" => operations}) when is_list(operations) do
    json(conn, %{results: GroupStay.Groups.apply_operations(operations)})
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_batch"}})
  end
end
